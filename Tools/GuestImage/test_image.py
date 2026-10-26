#!/usr/bin/env python3
"""Checks a built Linux base on the Mac before it is published.

Boots Tools/GuestImage/build/<id>/bundle in a hardware-accelerated VM the way the app does
(direct kernel boot, agent on a virtio serial port, packages over 9p), then:
greets the agent, installs toolchains from Catalog/catalog.json and runs their commands, starts the
editor and checks that it answers, and shuts the guest down.

Usage: test_image.py <id> [toolchain id ...]     default toolchains: python-3 nodejs-24 rust zig
"""
import hashlib
import json
import os
import pathlib
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CACHE = HERE / "build" / "packages"


class Agent:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.connect(str(path))
        self.socket.settimeout(1)
        self.buffer = b""
        self.next_id = 1

    def call(self, command, timeout=120):
        request_id = self.next_id
        self.next_id += 1
        try:
            self.socket.sendall((json.dumps({"id": request_id, "command": command}) + "\n").encode())
        except TimeoutError:
            return None  # Nobody reads the port yet: the guest is still booting.
        deadline = time.time() + timeout
        while time.time() < deadline:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                frame = json.loads(line)
                if "reply" in frame and frame["reply"]["id"] == request_id:
                    return frame["reply"]
            try:
                self.buffer += self.socket.recv(65536)
            except socket.timeout:
                pass
        return None


def step(message):
    print(f"[test {time.strftime('%H:%M:%S')}] {message}", flush=True)


def fetch_verified(package):
    """Downloads a catalog package once into the cache and checks its checksum."""
    CACHE.mkdir(parents=True, exist_ok=True)
    name = f"{package['sha256']}.{package['format']}"
    target = CACHE / name
    if not target.exists():
        step(f"downloading {package['url'].rsplit('/', 1)[-1]}")
        data = urllib.request.urlopen(urllib.request.Request(package["url"], headers={"User-Agent": "Runfern-test"})).read()
        if hashlib.sha256(data).hexdigest() != package["sha256"]:
            sys.exit(f"checksum mismatch for {package['url']}")
        target.write_bytes(data)
    return name


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    image_id = sys.argv[1]
    wanted = sys.argv[2:] or ["python-3", "nodejs-24", "rust", "zig"]
    bundle = HERE / "build" / image_id / "bundle"
    manifest = json.loads((bundle / "image.json").read_text())
    catalog = json.loads((ROOT / "Catalog/catalog.json").read_text())
    image = next(i for i in catalog["baseImages"] if i["id"] == image_id)
    toolchains = [t for t in catalog["toolchains"] if t["id"] in wanted and t["id"] in image["supportedToolchains"]]

    work = pathlib.Path(tempfile.mkdtemp(prefix="runfern-test-"))
    packages = work / "packages"
    packages.mkdir()
    for toolchain in toolchains:
        for package in toolchain["packages"]:
            name = fetch_verified(package)
            os.link(CACHE / name, packages / name) if not (packages / name).exists() else None
    workspace = work / "workspace"
    workspace.mkdir()
    overlay = work / "overlay.qcow2"
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", bundle / "disk.qcow2", overlay], check=True)
    port = 28000 + secrets.randbelow(1000)
    agent_socket = work / "agent.sock"
    qemu = subprocess.Popen([
        "qemu-system-aarch64", "-nodefaults", "-no-user-config", "-display", "none", "-machine", "virt",
        "-accel", "hvf", "-cpu", "host", "-smp", "4", "-m", "3072",
        "-kernel", bundle / "vmlinuz", "-initrd", bundle / "initrd.img", "-append", manifest["kernelCommandLine"],
        "-drive", f"if=none,id=d0,file={overlay},format=qcow2", "-device", "virtio-blk-pci,drive=d0",
        "-netdev", f"user,id=net0,hostfwd=tcp:127.0.0.1:{port}-:8080", "-device", "virtio-net-pci,netdev=net0,romfile=",
        "-device", "virtio-serial-pci", "-chardev", f"socket,id=agent,server=on,wait=off,path={agent_socket}",
        "-device", "virtserialport,chardev=agent,name=nrw.cyber.runfern.agent",
        "-fsdev", f"local,id=packages,security_model=none,readonly=on,path={packages}",
        "-device", "virtio-9p-pci,fsdev=packages,mount_tag=packages",
        "-serial", f"file:{work / 'console.log'}"], stderr=open(work / "qemu.log", "w"))
    failed = None
    try:
        for _ in range(50):
            if agent_socket.exists():
                break
            time.sleep(0.2)
        agent = Agent(agent_socket)
        token = secrets.token_urlsafe(32)
        start = time.time()
        while not (reply := agent.call({"hello": {"protocolVersion": manifest["agentProtocolVersion"], "sessionToken": token}}, 5)):
            if qemu.poll() is not None:
                raise RuntimeError(f"QEMU ended: {(work / 'qemu.log').read_text().strip()}")
            if time.time() - start > 300:
                raise RuntimeError("the agent did not answer")
        step(f"agent answered after {time.time() - start:.0f} s: {reply['payload']}")
        for toolchain in toolchains:
            command = {"installToolchain": {
                "id": toolchain["id"], "revision": toolchain["revision"],
                "packages": [{"file": f"{p['sha256']}.{p['format']}", "format": p["format"], "installRoot": p["installRoot"],
                              "stripComponents": p["stripComponents"]} for p in toolchain["packages"]],
                "commands": toolchain["commands"], "environment": toolchain["environment"]}}
            reply = agent.call(command, 900)
            if not reply or not reply["ok"]:
                raise RuntimeError(f"installing {toolchain['id']} failed: {reply}")
            step(f"installed {toolchain['family']} {toolchain['version']}")
        if not (agent.call({"startIDE": {"port": 8080}}, 300) or {}).get("ok"):
            raise RuntimeError("the editor did not start")
        # The editor trades the token for a cookie and redirects; the cookie has to come along.
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor())
        status = opener.open(f"http://127.0.0.1:{port}/?tkn={token}", timeout=60).status
        step(f"editor HTTP status {status}")
        if status != 200:
            raise RuntimeError("the editor did not answer")
        agent.call({"shutdown": {}}, 60)
        qemu.wait(timeout=120)
        step(f"PASSED {image_id} ({manifest['kernelVersion']})")
    except Exception as error:
        failed = error
    finally:
        if qemu.poll() is None:
            qemu.kill()
        if failed:
            console = work / "console.log"
            print(console.read_text(errors="replace")[-3000:] if console.exists() else "(no console output)")
            sys.exit(f"FAILED {image_id}: {failed!r}; files kept in {work}")
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
