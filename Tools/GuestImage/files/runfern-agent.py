#!/usr/bin/env python3
"""Runfern GuestAgent: the Linux side of the agent protocol (Plan 4.1).

Talks to the app over the virtio-serial port /dev/virtio-ports/nrw.cyber.runfern.agent.
Every frame is one JSON object per line, in the exact shape Swift's Codable produces for
AgentRequest, AgentFrame.reply, and AgentFrame.event (see AgentMessages.swift).
"""
import json
import re
import shlex
import shutil
import os
import socket
import subprocess
import sys
import threading
import time
import zipfile

PROTOCOL_VERSION = 1
AGENT_VERSION = "1.1.0"
PORT = "/dev/virtio-ports/nrw.cyber.runfern.agent"
STATE_DIR = "/var/lib/runfern"
INSTALLED = os.path.join(STATE_DIR, "toolchains.json")
PACKAGES = "/mnt/runfern-packages"
ENVIRONMENT = os.path.join(STATE_DIR, "environment.json")
WORKSPACE = "/workspace"
# Parent folder of all working copies shared by the app; only the active project is bound to /workspace.
WORKSPACES = "/mnt/workspaces"
IDE_BINARY = "/opt/openvscode-server/bin/openvscode-server"
USER = "runfern"
EXTENSIONS_DIR = f"/home/{USER}/.openvscode-server/extensions"
MAX_LINE = 1 << 20


def console(message):
    """Mirrors agent activity to the serial console, which the app keeps as console.log."""
    try:
        with open("/dev/console", "w") as handle:
            handle.write(f"runfern-agent: {message}\n")
    except OSError:
        pass


class Agent:
    def __init__(self, channel):
        self.channel = channel
        self.write_lock = threading.Lock()
        # One package manager run at a time, also when the host repeats a request after resuming.
        self.install_lock = threading.Lock()
        self.session_token = None
        self.ide = None

    # Framing

    def send(self, frame):
        line = json.dumps(frame, separators=(",", ":")).encode() + b"\n"
        view = memoryview(line)
        with self.write_lock:
            while view:
                view = view[os.write(self.channel.fileno(), view):]

    def reply(self, request_id, ok=True, error=None, payload=None):
        body = {"id": request_id, "ok": ok, "payload": payload or {}}
        if error is not None:
            body["error"] = error
        self.send({"reply": body})

    def event(self, name, **fields):
        self.send({"event": {name: fields}})

    def log(self, line):
        self.event("log", line=line[-2000:])

    # Commands

    def handle(self, request):
        request_id = request["id"]
        (name, arguments), = request["command"].items()
        if name == "hello":
            if arguments["protocolVersion"] != PROTOCOL_VERSION:
                return self.reply(request_id, False, f"unsupported protocol {arguments['protocolVersion']}")
            self.session_token = arguments["sessionToken"]
            console("session opened")
            self.reply(request_id, payload={"protocolVersion": str(PROTOCOL_VERSION), "agentVersion": AGENT_VERSION})
            return self.event("ready", agentVersion=AGENT_VERSION)
        if name == "shutdown":
            self.stop_ide()
            self.reply(request_id)
            self.event("shutdownComplete")
            subprocess.run(["sync"])
            subprocess.Popen(["systemctl", "poweroff"])
            return
        if self.session_token is None:
            return self.reply(request_id, False, "session not opened")
        handler = getattr(self, "command_" + name, None)
        if handler is None:
            return self.reply(request_id, False, f"unknown command {name}")
        # Long commands run in the background so health checks stay responsive.
        threading.Thread(target=self.run_command, args=(handler, request_id, arguments), daemon=True).start()

    def run_command(self, handler, request_id, arguments):
        try:
            self.reply(request_id, payload=handler(**arguments) or {})
        except Exception as error:  # Reported to the host instead of ending the agent.
            self.reply(request_id, False, str(error))

    def command_healthCheck(self):
        if not os.path.ismount(WORKSPACE):
            raise RuntimeError("project folder is not mounted")
        if not os.access(IDE_BINARY, os.X_OK):
            raise RuntimeError("editor is not installed")
        return {"linux": "ok", "agent": "ok", "toolchains": ",".join(sorted(load_installed()))}

    def command_mountWorkspace(self, path):
        """Binds the active project's working copy to /workspace, where the editor opens it."""
        parts = [part for part in path.split("/") if part not in ("", ".")]
        if not parts or ".." in parts:
            raise RuntimeError(f"invalid workspace path {path}")
        os.listdir(WORKSPACES)  # Triggers the automount.
        source = os.path.join(WORKSPACES, *parts)
        if not os.path.isdir(source):
            raise RuntimeError("project folder not found")
        os.makedirs(WORKSPACE, exist_ok=True)
        if os.path.ismount(WORKSPACE):
            subprocess.run(["umount", "-l", WORKSPACE], check=True)
        subprocess.run(["mount", "--bind", source, WORKSPACE], check=True)
        console("workspace mounted")
        return {}

    def command_mountFolder(self, port, token):
        """Mounts a folder in Files that the app serves over 9P on its loopback, reached via 10.0.2.2."""
        if not isinstance(port, int) or not 0 < port < 65536 or not re.fullmatch(r"[A-Za-z0-9_-]{16,128}", token):
            raise RuntimeError("invalid folder share")
        os.makedirs(WORKSPACE, exist_ok=True)
        if os.path.ismount(WORKSPACE):
            subprocess.run(["umount", "-l", WORKSPACE], check=True)
        options = f"trans=tcp,port={port},version=9p2000.L,msize=524288,aname={token}"
        # Right after boot the network may not be configured yet.
        for attempt in range(30):
            result = subprocess.run(["mount", "-t", "9p", "-o", options, "10.0.2.2", WORKSPACE],
                                    capture_output=True, text=True)
            if result.returncode == 0:
                console("folder mounted")
                return {}
            time.sleep(1)
        raise RuntimeError(f"folder could not be mounted: {result.stderr.strip()}")

    def command_installToolchain(self, id, revision, packages, commands, environment):
        """Unpacks a toolchain's archives from the package folder; no package manager, no network."""
        with self.install_lock:
            installed = load_installed()
            if installed.get(id, 0) >= revision:
                return {"installed": id}
            console(f"installing {id} revision {revision}")
            os.listdir(PACKAGES)  # Triggers the automount.
            for index, package in enumerate(packages):
                self.event("progress", step=id, fraction=index / len(packages))
                unpack(os.path.join(PACKAGES, safe_name(package["file"])), package["format"],
                       package["installRoot"], package["stripComponents"])
            for name, target in commands.items():
                link = os.path.join("/usr/local/bin", safe_name(name))
                if os.path.lexists(link):
                    os.remove(link)
                os.symlink(target, link)
            variables = load_json(ENVIRONMENT, {})
            variables.update(environment)
            save_json(ENVIRONMENT, variables)
            write_profile(variables)
            installed[id] = revision
            save_json(INSTALLED, installed)
            self.event("progress", step=id, fraction=1.0)
            console(f"installed {id}")
            return {"installed": id}

    def command_removeToolchain(self, id, roots, commands):
        """Removes a toolchain's directories and commands; only paths below /opt/runfern are touched."""
        with self.install_lock:
            for root in roots:
                if not os.path.realpath(root).startswith("/opt/runfern/"):
                    raise RuntimeError(f"refusing to remove {root}")
                shutil.rmtree(root, ignore_errors=True)
            for name in commands:
                link = os.path.join("/usr/local/bin", safe_name(name))
                if os.path.islink(link):
                    os.remove(link)
            installed = load_installed()
            installed.pop(id, None)
            save_json(INSTALLED, installed)
            console(f"removed {id}")
        return {}

    def command_removeExtensions(self, ids):
        with self.install_lock:
            for extension in ids:
                remove_extension(extension)
                console(f"removed extension {extension}")
        return {}

    def command_installExtensions(self, files):
        """Installs VS Code extensions from .vsix files the app placed in the package folder."""
        with self.install_lock:
            os.listdir(PACKAGES)
            for index, file in enumerate(files):
                self.event("progress", step=file, fraction=index / max(len(files), 1))
                console(f"installing extension {file}")
                install_vsix(os.path.join(PACKAGES, safe_name(file)))
        return {"installed": str(len(files))}

    def command_applyEditorSettings(self, settings):
        """Writes the user's VS Code settings (from a Runfern preset). The editor picks them up live."""
        settings = json.loads(settings)
        if not isinstance(settings, dict):
            raise RuntimeError("settings must be a JSON object")
        directory = f"/home/{USER}/.openvscode-server/data/User"
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, "settings.json")
        with open(path + ".tmp", "w") as handle:
            json.dump(settings, handle, indent=2)
        os.replace(path + ".tmp", path)
        uid, gid = user_ids()
        for item in (f"/home/{USER}/.openvscode-server", f"/home/{USER}/.openvscode-server/data", directory, path):
            os.chown(item, uid, gid)
        console("editor settings applied")
        return {"keys": str(len(settings))}

    def command_startIDE(self, port):
        if self.ide is None or self.ide.poll() is not None:
            # Only connections presenting the session token reach the editor (Plan 4.8).
            token_file = os.path.join(STATE_DIR, "connection-token")
            with open(os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as handle:
                handle.write(self.session_token)
            os.chown(token_file, *user_ids())
            variables = [f"{key}={value}" for key, value in sorted(load_json(ENVIRONMENT, {}).items())]
            self.ide = subprocess.Popen(
                ["runuser", "-u", USER, "--", "env", *variables, IDE_BINARY, "--host", "0.0.0.0", "--port", str(port),
                 "--connection-token-file", token_file, "--accept-server-license-terms",
                 "--default-folder", WORKSPACE, "--disable-telemetry"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=WORKSPACE)
        wait_for_port(port, timeout=240)
        return {"port": str(port)}

    def command_forwardPort(self, guestPort):
        # The host forwards the port; the guest only reports whether something listens there.
        return {"listening": "true" if port_open(guestPort) else "false"}

    def stop_ide(self):
        if self.ide is not None and self.ide.poll() is None:
            self.ide.terminate()
            try:
                self.ide.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.ide.kill()


def load_installed():
    return load_json(INSTALLED, {})


def load_json(path, default):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def save_json(path, value):
    temporary = path + ".tmp"
    with open(temporary, "w") as handle:
        json.dump(value, handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def write_profile(variables):
    """Login shells get the toolchain variables too; the editor receives them directly."""
    lines = "".join(f"export {key}={shlex.quote(value)}\n" for key, value in sorted(variables.items()))
    with open("/etc/profile.d/runfern.sh", "w") as handle:
        handle.write(lines)


def safe_name(name):
    if not name or "/" in name or name.startswith("."):
        raise RuntimeError(f"invalid file name {name}")
    return name


def stripped(path, count):
    parts = [part for part in path.split("/") if part not in ("", ".")]
    if ".." in parts:
        raise RuntimeError(f"unsafe path in archive: {path}")
    return "/".join(parts[count:])


def unpack(archive, kind, root, strip):
    """Unpacks into a fresh directory and swaps it in, so an interrupted run leaves no half state."""
    staging = root + ".new"
    shutil.rmtree(staging, ignore_errors=True)
    os.makedirs(staging)
    if kind == "tar.gz":
        # Native tar is much faster than tarfile when the guest CPU is interpreted. GNU tar drops
        # leading slashes and refuses members containing "..".
        result = subprocess.run(["tar", "-xzf", archive, "-C", staging, f"--strip-components={int(strip)}",
                                 "--no-same-owner", "--delay-directory-restore"],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"unpacking failed: {result.stdout.strip()[-200:]}")
    elif kind == "zip":
        with zipfile.ZipFile(archive) as source:
            for info in source.infolist():
                name = stripped(info.filename, strip)
                if not name:
                    continue
                target = os.path.join(staging, name)
                if info.is_dir():
                    os.makedirs(target, exist_ok=True)
                    continue
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with source.open(info) as data, open(target, "wb") as output:
                    shutil.copyfileobj(data, output, 1 << 20)
                mode = (info.external_attr >> 16) & 0o777
                if mode:
                    os.chmod(target, mode)
    else:
        raise RuntimeError(f"unsupported archive format {kind}")
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(os.path.dirname(root), exist_ok=True)
    os.rename(staging, root)


def install_vsix(archive):
    """Installs a VS Code extension by unpacking it the way VS Code lays it out and registering it in
    extensions.json. Starting the editor's own installer would run Node.js, which takes minutes."""
    with zipfile.ZipFile(archive) as source:
        manifest = json.loads(source.read("extension/package.json"))
        identifier = f"{manifest['publisher']}.{manifest['name']}".lower()
        version = str(manifest["version"])
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9._-]*", identifier) \
                or not re.fullmatch(r"[0-9A-Za-z.+-]+", version):
            raise RuntimeError(f"invalid extension identity {identifier} {version}")
        folder = f"{identifier}-{version}"
        target = os.path.join(EXTENSIONS_DIR, folder)
        staging = target + ".new"
        shutil.rmtree(staging, ignore_errors=True)
        os.makedirs(staging)
        for info in source.infolist():
            if not info.filename.startswith("extension/") or info.is_dir():
                continue
            relative = os.path.normpath(info.filename[len("extension/"):])
            if relative.startswith("..") or os.path.isabs(relative):
                raise RuntimeError(f"unsafe path in extension: {info.filename}")
            destination = os.path.join(staging, relative)
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            with source.open(info) as data, open(destination, "wb") as output:
                shutil.copyfileobj(data, output, 1 << 20)
    # Other versions of the same extension are replaced.
    registry = remove_extension(identifier)
    shutil.rmtree(target, ignore_errors=True)
    os.rename(staging, target)
    registry.append({
        "identifier": {"id": identifier},
        "version": version,
        "location": {"$mid": 1, "fsPath": target, "external": "file://" + target, "path": target, "scheme": "file"},
        "relativeLocation": folder,
        "metadata": {"installedTimestamp": int(time.time() * 1000), "source": "vsix"},
    })
    save_extension_registry(registry)
    uid, gid = user_ids()
    for directory, _, names in os.walk(target):
        os.chown(directory, uid, gid)
        for name in names:
            os.chown(os.path.join(directory, name), uid, gid)
    return identifier, version


def extension_registry_path():
    return os.path.join(EXTENSIONS_DIR, "extensions.json")


def save_extension_registry(registry):
    path = extension_registry_path()
    with open(path + ".tmp", "w") as handle:
        json.dump(registry, handle)
    os.replace(path + ".tmp", path)
    os.chown(path, *user_ids())


def remove_extension(identifier):
    """Unregisters every version of an extension and deletes its folders; returns the new registry."""
    identifier = identifier.lower()
    registry = [entry for entry in load_json(extension_registry_path(), []) if isinstance(entry, dict)]
    kept = []
    for entry in registry:
        if entry.get("identifier", {}).get("id", "").lower() != identifier:
            kept.append(entry)
            continue
        location = entry.get("relativeLocation")
        if isinstance(location, str) and location and "/" not in location and not location.startswith("."):
            shutil.rmtree(os.path.join(EXTENSIONS_DIR, location), ignore_errors=True)
    if len(kept) != len(registry):
        save_extension_registry(kept)
    return kept


def user_ids():
    import pwd
    entry = pwd.getpwnam(USER)
    return entry.pw_uid, entry.pw_gid


def port_open(port):
    with socket.socket() as probe:
        probe.settimeout(0.5)
        return probe.connect_ex(("127.0.0.1", port)) == 0


def wait_for_port(port, timeout):
    deadline = time.monotonic() + timeout
    while not port_open(port):
        if time.monotonic() > deadline:
            raise RuntimeError("editor did not start in time")
        time.sleep(0.5)


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    while not os.path.exists(PORT):
        time.sleep(0.5)
    channel = open(PORT, "r+b", buffering=0)
    console("listening")
    agent = Agent(channel)
    buffer = b""
    while True:
        chunk = os.read(channel.fileno(), 65536)
        if not chunk:
            # The host is not connected; virtio-serial reports EOF until it is.
            time.sleep(0.2)
            continue
        buffer += chunk
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            if not line.strip():
                continue
            try:
                agent.handle(json.loads(line))
            except (ValueError, KeyError) as error:
                agent.log(f"Ignored malformed request: {error}")
        if len(buffer) > MAX_LINE:
            buffer = b""


if __name__ == "__main__":
    sys.exit(main())
