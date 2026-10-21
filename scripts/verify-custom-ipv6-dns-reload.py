#!/usr/bin/env python3
"""Exercise the production Cgo custom-DNS retargeter and private no-TUN core.
All sockets use dynamic loopback ports; no installed app/API or OS settings.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time

BRIDGE = r"""import Foundation
let path = CommandLine.arguments[1]
let port = Int32(CommandLine.arguments[2])!
let cpath = strdup(path)!
defer { free(cpath) }
guard let pointer = clashRetargetEnhancedDNSConfig(cpath, port) else { fatalError("no bridge reply") }
let result = String(cString: pointer)
free(pointer)
guard result.isEmpty else { fatalError("private custom-DNS retarget rejected: \(result)") }
"""

def port():
    for _ in range(20):
        sockets=[]
        try:
            first=socket.socket(socket.AF_INET6,socket.SOCK_STREAM);sockets.append(first)
            first.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
            first.bind(('::1',0));value=first.getsockname()[1]
            for family,kind,host in [(socket.AF_INET6,socket.SOCK_DGRAM,'::1'),(socket.AF_INET,socket.SOCK_STREAM,'127.0.0.1'),(socket.AF_INET,socket.SOCK_DGRAM,'127.0.0.1')]:
                s=socket.socket(family,kind);sockets.append(s);s.bind((host,value))
            return value
        except OSError:
            pass
        finally:
            for s in sockets:s.close()
    raise RuntimeError('could not allocate private dual-family fixture port')

NAME=b'\x07fixture\x04test\x00'
QUESTION=NAME+struct.pack('!HH',1,1)
PACKET=struct.pack('!6H',0x3a14,0x100,1,0,0,0)+QUESTION
IP=socket.inet_aton('127.0.0.123')
def answer(data):
    if len(data)<12 or data[:2]!=PACKET[:2]:return False
    _,flags,qd,an,_,_=struct.unpack('!6H',data[:12])
    if flags&15 or not flags&0x8000 or qd!=1 or data[12:12+len(QUESTION)]!=QUESTION:return False
    offset=12+len(QUESTION)
    try:
        for _ in range(an):
            while True:
                n=data[offset];offset+=1
                if n&0xc0==0xc0:offset+=1;break
                if n==0:break
                if n>63:return False
                offset+=n
            kind,klass,_,length=struct.unpack('!HHIH',data[offset:offset+10]);offset+=10
            payload=data[offset:offset+length];offset+=length
            if kind==1 and klass==1 and length==4 and payload==IP:return True
    except (IndexError,struct.error):return False
    return False

def receive(s,n):
    data=b''
    while len(data)<n:
        part=s.recv(n-len(data))
        if not part:raise OSError('closed private DNS connection')
        data+=part
    return data

def query(host,p,kind):
    family=socket.AF_INET6 if ':' in host else socket.AF_INET
    try:
        with socket.socket(family,kind) as s:
            s.settimeout(.3);s.connect((host,p))
            if kind==socket.SOCK_DGRAM:
                s.send(PACKET);data=s.recv(4096)
            else:
                s.sendall(struct.pack('!H',len(PACKET))+PACKET)
                length=struct.unpack('!H',receive(s,2))[0]
                if length>16384:return False
                data=receive(s,length)
            return answer(data)
    except OSError:return False

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core',type=Path,required=True)
    parser.add_argument('--bridge-directory',type=Path,required=True)
    args=parser.parse_args()
    if os.geteuid()==0:raise RuntimeError('run unprivileged')
    bridge=args.bridge_directory.resolve();core=args.core.resolve()
    root=Path(tempfile.mkdtemp(prefix='clashfx-custom-ipv6-dns-'));root.chmod(0o700)
    print('Artifacts:',root,flush=True)
    source=root/'main.swift';source.write_text(BRIDGE);runner=root/'retarget'
    with (root/'compile.log').open('w') as log:
        subprocess.run(['swiftc','-import-objc-header',str(bridge/'goClash.h'),'-I',str(bridge),str(source),str(bridge/'goClash.a'),'-framework','Foundation','-lresolv','-o',str(runner)],stdout=log,stderr=subprocess.STDOUT,check=True)
    for label,listen_host,ref_host,changed in [('same-port','::1','::1',False),('changed-port','::1','::1',True),('wildcard-v6','::','::1',True),('wildcard-v4','::','127.0.0.1',True),('mapped-v4','::ffff:127.0.0.1','::ffff:127.0.0.1',True)]:
        home=root/label;home.mkdir(mode=0o700)
        before=port();after=port() if changed else before
        if changed:
            while after==before:after=port()
        listen=f'[{listen_host}]:{before}'
        reference=f'udp://[{ref_host}]:{before}' if ':' in ref_host else f'udp://{ref_host}:{before}'
        file=home/'config.json'
        file.write_text(json.dumps({'mixed-port':0,'external-controller':'','tun':{'enable':False},'dns':{'enable':True,'listen':listen,'use-hosts':True,'nameserver':['udp://127.0.0.1:9'],'proxy-server-nameserver':[reference]},'hosts':{'fixture.test':'127.0.0.123'},'rules':['MATCH,DIRECT']}));file.chmod(0o600)
        env=dict(os.environ,HOME=str(home),XDG_CONFIG_HOME=str(home),SAFE_PATHS=str(home))
        with (home/'retarget.log').open('w') as log:subprocess.run([str(runner),str(file),str(after)],env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=15)
        expected=f'udp://[{ref_host}]:{after}' if ':' in ref_host else f'udp://{ref_host}:{after}'
        if label=='mapped-v4':expected=f'udp://127.0.0.1:{after}'
        assert expected in file.read_text(), 'owned bootstrap reference did not follow the listener'
        assert file.stat().st_mode & 0o777 == 0o600, 'retargeted snapshot permissions changed' 
        if listen_host=='::':
            assert f'[::]:{after}' in file.read_text(), 'wildcard bind address changed'
            print('PASS:',label,'Cgo projection/owned aliases (no wildcard process launched)',flush=True)
            continue
        # The retargeter writes YAML; verify the exact endpoint through the real
        # core and DNS protocol below instead of relying on text formatting.
        with (home/'core.log').open('w') as log:
            process=subprocess.Popen([str(core),'-d',str(home),'-f',str(file)],env=env,stdout=log,stderr=subprocess.STDOUT)
            try:
                hosts=[listen_host] if listen_host!='::' else ['::1','127.0.0.1']
                deadline=time.monotonic()+8
                while True:
                    if process.poll() is not None:raise RuntimeError(f'{label}: private core exited {process.returncode}')
                    if all(query(h,after,k) for h in hosts for k in [socket.SOCK_DGRAM,socket.SOCK_STREAM]):break
                    if time.monotonic()>=deadline:raise RuntimeError(f'{label}: IPv6/dual-stack DNS failed')
                    time.sleep(.03)
                print('PASS:',label,'Cgo retarget + actual DNS UDP/TCP',hosts,flush=True)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:process.wait(timeout=3)
                    except subprocess.TimeoutExpired:process.kill();process.wait(timeout=3)
    print('Private custom IPv6 reload bridge/core fixture passed')

if __name__=='__main__':main()
