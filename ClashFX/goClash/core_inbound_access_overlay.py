"""Synchronize immutable inbound access-prefix snapshots during reload."""
from __future__ import annotations
import hashlib
import pathlib
import os
import stat
import subprocess

EXPECTED = {
    'adapter/inbound/auth.go': '7bf77f4ab816f5e08feab3484d522f9c0ff3fea8149288d5e03682885dfa18af',
    'adapter/inbound/ipfilter.go': 'ee87266cee609fb3799907b907cd4b26036d97c1fd54af80528af2b4cbc69ac0',
}

def replace_once(source: str, old: str, new: str, label: str) -> str:
    if source.count(old) != 1:
        raise RuntimeError(f"Pinned inbound access shape changed: {label}")
    return source.replace(old, new, 1)


def patch_inbound_access_state(root: pathlib.Path) -> None:
    root = pathlib.Path(root)
    sources = {}
    for relative, expected in EXPECTED.items():
        data = (root / relative).read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise RuntimeError(f"Pinned inbound access source changed: {relative}")
        sources[relative] = data.decode()
    auth = sources['adapter/inbound/auth.go']
    auth = replace_once(auth, 'skipAuthPrefixes = prefixes', 'accessPrefixesMu.Lock()\n\tdefer accessPrefixesMu.Unlock()\n\tskipAuthPrefixes = append([]netip.Prefix(nil), prefixes...)', 'auth setter')
    auth = replace_once(auth, 'return skipAuthPrefixes', 'accessPrefixesMu.RLock()\n\tdefer accessPrefixesMu.RUnlock()\n\treturn append([]netip.Prefix(nil), skipAuthPrefixes...)', 'auth getter')
    auth = replace_once(auth, 'return prefixesContains(skipAuthPrefixes, addr)', 'accessPrefixesMu.RLock()\n\tdefer accessPrefixesMu.RUnlock()\n\treturn prefixesContains(skipAuthPrefixes, addr)', 'auth reader')
    ip = sources['adapter/inbound/ipfilter.go']
    ip = replace_once(ip, '"net/netip"', '"net/netip"\n\t"sync"', 'access mutex import')
    ip = replace_once(ip, 'var lanAllowedIPs', 'var accessPrefixesMu sync.RWMutex\n\nvar lanAllowedIPs', 'access mutex')
    for variable, field in [('lanAllowedIPs', 'allowed'), ('lanDisAllowedIPs', 'disallowed')]:
        ip = replace_once(ip, variable + ' = prefixes', 'accessPrefixesMu.Lock()\n\tdefer accessPrefixesMu.Unlock()\n\t' + variable + ' = append([]netip.Prefix(nil), prefixes...)', field + ' setter')
        ip = replace_once(ip, 'return '+variable, 'accessPrefixesMu.RLock()\n\tdefer accessPrefixesMu.RUnlock()\n\treturn append([]netip.Prefix(nil), '+variable+'...)', field + ' getter')
        ip = replace_once(ip, 'return prefixesContains('+variable+', addr)', 'accessPrefixesMu.RLock()\n\tdefer accessPrefixesMu.RUnlock()\n\treturn prefixesContains('+variable+', addr)', field + ' reader')
    ip = replace_once(ip, 'return isAllowed(ipAddr) && !isDisAllowed(ipAddr)', 'accessPrefixesMu.RLock()\n\tdefer accessPrefixesMu.RUnlock()\n\treturn prefixesContains(lanAllowedIPs, ipAddr) && !prefixesContains(lanDisAllowedIPs, ipAddr)', 'combined filter read')
    ip += '''
// SetAccessPrefixes publishes one immutable access-policy snapshot.
func SetAccessPrefixes(skip, allowed, disallowed []netip.Prefix) {
 accessPrefixesMu.Lock()
 defer accessPrefixesMu.Unlock()
 skipAuthPrefixes=append([]netip.Prefix(nil),skip...)
 lanAllowedIPs=append([]netip.Prefix(nil),allowed...)
 lanDisAllowedIPs=append([]netip.Prefix(nil),disallowed...)
}
'''
    executor_path = root / 'hub/executor/executor.go'
    executor = replace_once(executor_path.read_text(),
        '\tinbound.SetSkipAuthPrefixes(general.SkipAuthPrefixes)\n\tinbound.SetAllowedIPs(general.LanAllowedIPs)\n\tinbound.SetDisAllowedIPs(general.LanDisAllowedIPs)',
        '\tinbound.SetAccessPrefixes(general.SkipAuthPrefixes, general.LanAllowedIPs, general.LanDisAllowedIPs)', 'reload policy publication')
    for path, source in [(root/'adapter/inbound/auth.go', auth), (root/'adapter/inbound/ipfilter.go', ip), (executor_path, executor)]:
        formatted = subprocess.check_output(['gofmt'], input=source, text=True)
        os.chmod(path, path.stat().st_mode | stat.S_IWUSR)
        path.write_text(formatted)
