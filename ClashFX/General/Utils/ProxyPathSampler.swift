import Foundation

/// Probes the proxy nodes the user actually selected through the core's REST
/// API and classifies why a failing node fails. Callbacks arrive on the main queue.
///
/// Classification asks the core's own DNS about the node hostname. A profile
/// that resolves node hostnames through a dedicated resolver can disagree with
/// that answer; the worst outcome is then "unreachable", which is only retried
/// and reported, never flushed or reloaded.
final class ProxyPathSampler {
    static let delayProbeURL = "https://www.gstatic.com/generate_204"
    static let delayTimeoutMilliseconds = 5000
    static let leafLimit = 3

    private let session: URLSession
    private let queue = DispatchQueue(label: "com.clashfx.proxy-path-sampler", qos: .utility)

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        session = URLSession(configuration: configuration)
    }

    func sample(configName: String, completion: @escaping (ProxyPathVerdict, [ProxyPathSample]) -> Void) {
        fetchNodes { [weak self] nodes in
            guard let self = self, let nodes = nodes else {
                DispatchQueue.main.async { completion(.noSample, []) }
                return
            }
            let leaves = SelectedLeafResolver.leaves(in: nodes, limit: Self.leafLimit)
            guard !leaves.isEmpty else {
                DispatchQueue.main.async { completion(.noSample, []) }
                return
            }
            self.loadServers(configName: configName) { servers in
                self.probe(leaves: leaves, servers: servers) { samples in
                    let verdict = ProxyPathEvaluator.verdict(for: samples)
                    DispatchQueue.main.async { completion(verdict, samples) }
                }
            }
        }
    }

    func flushDNSCache(completion: @escaping () -> Void) {
        guard let request = makeRequest(path: "/cache/dns/flush", query: [], method: "POST") else {
            DispatchQueue.main.async { completion() }
            return
        }
        session.dataTask(with: request) { _, response, _ in
            Logger.log("[Proxy Path] flush DNS cache: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            DispatchQueue.main.async { completion() }
        }.resume()
    }

    // MARK: - Requests

    private func fetchNodes(completion: @escaping ([String: ProxyPathNode]?) -> Void) {
        guard let request = makeRequest(path: "/proxies", query: [], method: "GET") else {
            completion(nil)
            return
        }
        session.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let data = data,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let proxies = root["proxies"] as? [String: Any] else {
                completion(nil)
                return
            }
            var nodes: [String: ProxyPathNode] = [:]
            for (name, value) in proxies {
                guard let entry = value as? [String: Any], let type = entry["type"] as? String else { continue }
                nodes[name] = ProxyPathNode(type: type, now: entry["now"] as? String)
            }
            completion(nodes)
        }.resume()
    }

    private func loadServers(configName: String, completion: @escaping ([String: String]) -> Void) {
        ConfigManager.getConfigPath(configName: configName) { [queue] path in
            queue.async {
                let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                completion(ProxyServerIndex.servers(inYAML: text))
            }
        }
    }

    private func probe(leaves: [String], servers: [String: String],
                       completion: @escaping ([ProxyPathSample]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var samples: [ProxyPathSample] = []
        for leaf in leaves {
            group.enter()
            probeDelay(leaf: leaf) { [weak self] answered in
                if answered {
                    lock.lock(); samples.append(ProxyPathSample(leaf: leaf, failure: nil)); lock.unlock()
                    group.leave()
                    return
                }
                guard let self = self else {
                    lock.lock(); samples.append(ProxyPathSample(leaf: leaf, failure: .unknown)); lock.unlock()
                    group.leave()
                    return
                }
                self.classifyFailure(leaf: leaf, servers: servers) { kind in
                    lock.lock(); samples.append(ProxyPathSample(leaf: leaf, failure: kind)); lock.unlock()
                    group.leave()
                }
            }
        }
        group.notify(queue: queue) {
            completion(samples.sorted { $0.leaf < $1.leaf })
        }
    }

    private func probeDelay(leaf: String, completion: @escaping (Bool) -> Void) {
        let name = Self.encodePathComponent(leaf)
        let query = [URLQueryItem(name: "url", value: Self.delayProbeURL),
                     URLQueryItem(name: "timeout", value: "\(Self.delayTimeoutMilliseconds)")]
        guard let request = makeRequest(path: "/proxies/\(name)/delay", query: query, method: "GET") else {
            completion(false)
            return
        }
        session.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let delay = json["delay"] as? Int, delay > 0 else {
                completion(false)
                return
            }
            completion(true)
        }.resume()
    }

    private func classifyFailure(leaf: String, servers: [String: String],
                                 completion: @escaping (ProxyPathFailureKind) -> Void) {
        guard let host = servers[leaf] else { completion(.unknown); return }
        if ProxyServerIndex.isIPLiteral(host) { completion(.unreachable); return }
        let query = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
        guard let request = makeRequest(path: "/dns/query", query: query, method: "GET") else {
            completion(.unknown)
            return
        }
        session.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                completion(.nodeResolution)
                return
            }
            let answers = ((data.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any])?["Answer"]
            completion((answers as? [Any])?.isEmpty == false ? .unreachable : .nodeResolution)
        }.resume()
    }

    private func makeRequest(path: String, query: [URLQueryItem], method: String) -> URLRequest? {
        guard var components = URLComponents(string: ConfigManager.apiUrl + path) else { return nil }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.httpMethod = method
        for header in ApiRequest.authHeader() {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return request
    }

    private static func encodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
