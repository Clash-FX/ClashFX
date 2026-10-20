#!/usr/bin/env python3
"""Pure regressions for the hosted DNS oracle and YAML-compatible JSON; no network."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
let parser=Parser()
let question:[UInt8]=[1,97,0,0,1,0,1]
let header:[UInt8]=[0xca,0xfe,0x81,0x80,0,1,0,1,0,0,0,1]
let query:[UInt8]=[0xca,0xfe,1,0,0,1,0,0,0,0,0,0]+question
let owner:[UInt8]=[0xc0,0x0c,0,1,0,1,0,0,0,1,0,4]
let valid=header+question+owner+[198,19,0,7]+[0,0,16,0,1,0,0,0,1,0,4,1,2,3,4]
precondition(parser.dnsAAnswerMatchesRange(valid,range:"198.19.0.0/16",question:query))
precondition(!parser.dnsAAnswerMatchesRange(valid,range:"198.18.0.0/16",question:query))
let falseTail=header+question+owner+[1,1,1,1]+[0,0,16,0,1,0,0,0,1,0,4,198,18,0,7]
precondition(!parser.dnsAAnswerMatchesRange(falseTail,range:"198.18.0.0/16",question:query))
precondition(!parser.dnsAAnswerMatchesRange(Array(valid.prefix(20)),range:"198.19.0.0/16",question:query))
precondition(!parser.dnsAAnswerMatchesRange(valid,range:"198.19.invalid.0.0/16",question:query))
print("Pure DNS parser checks passed: actual A/CIDR, unrelated extra record, truncation")

var noQuestion=valid;noQuestion[5]=0
precondition(!parser.dnsAAnswerMatchesRange(noQuestion,range:"198.19.0.0/16",question:query))
var otherQuestion=valid;otherQuestion[13]=98
precondition(!parser.dnsAAnswerMatchesRange(otherQuestion,range:"198.19.0.0/16",question:query))
var wrongType=valid;wrongType[16]=28
precondition(!parser.dnsAAnswerMatchesRange(wrongType,range:"198.19.0.0/16",question:query))
print("Question count/name/type matching checks passed")
let fixture:[String:Any] = ["cidr":"198.18.0.1/16","url":"https://example.com/dns-query"]
let encoded = try yamlCompatibleJSON(fixture)
precondition(!String(decoding:encoded,as:UTF8.self).contains("\\/"))
let decoded = try JSONSerialization.jsonObject(with:encoded) as! [String:String]
precondition(decoded["cidr"] == "198.18.0.1/16" && decoded["url"] == "https://example.com/dns-query")
print("YAML-compatible JSON keeps CIDR/URL slashes and roundtrips unchanged")
'''


def main():
    source = (ROOT / "scripts/hosted-runtime-config-acceptance.swift").read_text()
    start = source.index("    func dnsAAnswerMatchesRange(")
    end = source.index("    func probeDNS(", start)
    parser = source[start:end]
    encoding_start = source.index("private func yamlCompatibleJSON(")
    encoding_end = source.index("private final class Acceptance", encoding_start)
    encoding = source[encoding_start:encoding_end]
    with tempfile.TemporaryDirectory(prefix="clashfx-hosted-dns-parser-") as directory:
        test = Path(directory) / "main.swift"
        test.write_text("import Foundation\nstruct Parser {\n" + parser + "\n}\n" + encoding + HARNESS)
        subprocess.run(["swift", str(test)], check=True, timeout=60)

if __name__ == "__main__":
    main()
