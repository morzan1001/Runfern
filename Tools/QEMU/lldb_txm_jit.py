"""LLDB stand-in for StikDebug's utmjit.js, to test the JIT backend from Xcode.

On devices with the Trusted Execution Monitor, QEMU stops at `brk #0x69` with the code region in
x0 (address) and x1 (length). A debugger write to every 16 KB page lets that page execute; then
the program continues after the breakpoint.

Usage in Xcode's debug console:
    command script import Tools/QEMU/lldb_txm_jit.py
    txm_prepare          (when the app stopped at brk #0x69)
    txm_run [minutes] [detach]
                         (keeps the app running and answers every brk #0x69; with "detach" it
                         leaves after the first one, exactly like StikDebug's utmjit.js)
"""
import time

import lldb

PAGE = 0x4000
BRK_0X69 = 0xD4200D20


def txm_prepare(debugger, command, result, internal_dict):
    process = debugger.GetSelectedTarget().GetProcess()
    thread = process.GetSelectedThread()
    frame = thread.GetFrameAtIndex(0)
    pc = frame.GetPC()
    error = lldb.SBError()
    instruction = process.ReadUnsignedFromMemory(pc, 4, error)
    if not error.Success() or instruction != BRK_0X69:
        result.AppendMessage("not stopped at brk #0x69 (pc=0x%x, instruction=0x%x)" % (pc, instruction))
        return
    address = frame.FindRegister("x0").GetValueAsUnsigned()
    length = frame.FindRegister("x1").GetValueAsUnsigned()
    # The region is freshly mapped and still zero, so zeros can be written in large blocks; each
    # debugger write authorizes every page it touches.
    chunk = int(command) if command.strip() else 0x100000
    zeros = bytes(chunk)
    started = time.time()
    for offset in range(0, length, chunk):
        size = min(chunk, length - offset)
        process.WriteMemory(address + offset, zeros[:size], error)
        if (offset + size) % (8 << 20) == 0:
            elapsed = time.time() - started
            print("[txm] %d of %d MB after %.0f s" % ((offset + size) >> 20, length >> 20, elapsed), flush=True)
        if not error.Success():
            result.AppendMessage("write failed at 0x%x: %s" % (address + offset, error))
            return
    # Continue after the breakpoint. LLDB refuses register writes here, so the pc (register 0x20
    # in debugserver's numbering) is set with a raw packet, as StikDebug does.
    value = (pc + 4).to_bytes(8, "little").hex()
    ret = lldb.SBCommandReturnObject()
    debugger.GetCommandInterpreter().HandleCommand(
        'process plugin packet send "P20=%s;thread:%x;"' % (value, thread.GetThreadID()), ret)
    if "OK" not in ret.GetOutput():
        result.AppendMessage("could not move pc past the breakpoint: %s %s" % (ret.GetOutput(), ret.GetError()))
        return
    result.AppendMessage("prepared %d MB at 0x%x in %.1f s; continue to run"
                         % (length >> 20, address, time.time() - started))


def txm_run(debugger, command, result, internal_dict):
    debugger.SetAsync(False)
    process = debugger.GetSelectedTarget().GetProcess()
    options = command.split()
    minutes = float(options[0]) if options else 15
    detach_after_prepare = "detach" in options
    deadline = time.time() + 60 * minutes
    while time.time() < deadline:
        process.Continue()
        state = process.GetState()
        if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed):
            print("[txm] process ended (state %d, exit %s)" % (state, process.GetExitStatus()))
            return
        if state != lldb.eStateStopped:
            continue
        thread = process.GetSelectedThread()
        frame = thread.GetFrameAtIndex(0)
        error = lldb.SBError()
        if process.ReadUnsignedFromMemory(frame.GetPC(), 4, error) == BRK_0X69:
            started = time.time()
            ret = lldb.SBCommandReturnObject()
            txm_prepare(debugger, "", ret, internal_dict)
            print("[txm] %s in %.1f s" % (ret.GetOutput().strip(), time.time() - started), flush=True)
            if detach_after_prepare:
                process.Detach()
                print("[txm] detached", flush=True)
                return
            continue
        description = thread.GetStopDescription(200)
        print("[txm] stop: %s in %s" % (description, frame.GetFunctionName()), flush=True)
        if "EXC_BAD_ACCESS" in description or "EXC_BAD_INSTRUCTION" in description:
            for f in thread.frames[:15]:
                print("    %s" % f)
            return
    print("[txm] time limit reached; detaching")
    process.Detach()


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f lldb_txm_jit.txm_prepare txm_prepare")
    debugger.HandleCommand("command script add -f lldb_txm_jit.txm_run txm_run")
