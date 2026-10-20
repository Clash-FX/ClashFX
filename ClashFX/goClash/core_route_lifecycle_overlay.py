"""Serialize pinned REST endpoint setup/teardown; only serving is asynchronous."""
from __future__ import annotations
import hashlib
import os
import pathlib
import stat
import subprocess

SOURCE_SHA256 = "0ee018452ed05a5ba0c83c89843a5c930574810dbaca472f06820dedf13f98b9"


def patch_route_lifecycle(root: pathlib.Path) -> None:
    path = pathlib.Path(root) / "hub/route/server.go"
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != SOURCE_SHA256:
        raise RuntimeError("Pinned REST lifecycle source changed")
    source = data.decode()

    def replace(old: str, new: str) -> None:
        nonlocal source
        if source.count(old) != 1:
            raise RuntimeError("Pinned REST lifecycle shape changed: " + old[:80])
        source = source.replace(old, new, 1)

    replace('"strings"', '"strings"\n\t"sync"\n\t"fmt"')
    replace('func ReCreateServer(cfg *Config) {', '''var serverLifecycleMu sync.Mutex
var httpEndpoint, tlsEndpoint, unixEndpoint, pipeEndpoint net.Listener

func ReCreateServer(cfg *Config) {
    serverLifecycleMu.Lock()
    defer serverLifecycleMu.Unlock()
    reCreateServer(cfg)
}

// ReCreateServerAndValidate makes endpoint binding part of startup confirmation.
func ReCreateServerAndValidate(cfg *Config) error {
    serverLifecycleMu.Lock()
    defer serverLifecycleMu.Unlock()
    reCreateServer(cfg)
    for _, endpoint := range []struct { address string; listener net.Listener; label string }{
        {cfg.Addr, httpEndpoint, "HTTP"}, {cfg.TLSAddr, tlsEndpoint, "TLS"},
        {cfg.UnixAddr, unixEndpoint, "Unix"}, {cfg.PipeAddr, pipeEndpoint, "pipe"},
    } {
        if endpoint.address != "" && endpoint.listener == nil {
            return fmt.Errorf("external controller %s endpoint failed to bind", endpoint.label)
        }
    }
    return nil
}

func reCreateServer(cfg *Config) {''')
    for name in ('start', 'startTLS', 'startUnix', 'startPipe'):
        replace('go ' + name + '(cfg)', name + '(cfg)')
    for server, label, argument in [
        ('httpServer', '', 'l'), ('tlsServer', ' tls', 'tls.NewListener(l, tlsConfig)'),
        ('unixServer', ' unix', 'l'), ('pipeServer', ' pipe', 'l'),
    ]:
        endpoint = server.replace('Server', 'Endpoint')
        replace('func ' + {'httpServer':'start', 'tlsServer':'startTLS', 'unixServer':'startUnix', 'pipeServer':'startPipe'}[server] + '(cfg *Config) {',
                'func ' + {'httpServer':'start', 'tlsServer':'startTLS', 'unixServer':'startUnix', 'pipeServer':'startPipe'}[server] + '(cfg *Config) {\n' +
                f'if {endpoint} != nil {{ _ = {endpoint}.Close(); {endpoint} = nil }}')
        old = f'''\t\t{server} = server
\t\tif err = server.Serve({argument}); err != nil {{
\t\t\tlog.Errorln("External controller{label} serve error: %s", err)
\t\t}}'''
        new = f'''\t\t{server} = server
        {endpoint} = {argument}
        // Capture the owned endpoint, never the replaceable package pointer.
        go func(server *http.Server, endpoint net.Listener) {{
            defer endpoint.Close()
            if err := server.Serve(endpoint); err != nil {{
                log.Errorln("External controller{label} serve error: %s", err)
            }}
        }}(server, {endpoint})'''
        replace(old, new)
    # TLS policy construction can fail after binding; release that endpoint too.
    replace('''\t\tlog.Infoln("RESTful API tls listening at: %s", l.Addr().String())''', '''        committed := false
        defer func() { if !committed { _ = l.Close() } }()
\t\tlog.Infoln("RESTful API tls listening at: %s", l.Addr().String())''')
    replace('\t\ttlsServer = server', '\t\ttlsServer = server\n        committed = true')
    source = subprocess.check_output(['gofmt'], input=source, text=True)
    os.chmod(path, path.stat().st_mode | stat.S_IWUSR)
    path.write_text(source)
