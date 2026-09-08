# -*- coding: utf-8 -*-
# verify_panel.py — 用 frida 在设备上直接 dlopen 设置面板 bundle，确认能否加载。
# 前置：设备 USB 连接 + frida-server 在跑 + deb 已安装(重装并注销过)。
# 用法: python verify_panel.py
import frida, time, sys

JS = open(__file__.replace('.py', '.js'), 'r', encoding='utf-8').read()

def main():
    try:
        dev = frida.get_usb_device(timeout=10)
    except Exception as e:
        print("[ERR] 找不到 USB 设备(未连接或未起 frida-server):", e); sys.exit(1)
    print("[DEV] %s" % dev.name)
    # 挂到 SpringBoard（有 dlopen，且能代表正常进程加载行为）
    pid = None
    for p in dev.enumerate_processes():
        if p.name == "SpringBoard":
            pid = p.pid; break
    if not pid:
        print("[ERR] 未找到 SpringBoard 进程"); sys.exit(1)
    print("[ATTACH] SpringBoard pid=%d" % pid)
    try:
        sess = dev.attach(pid)
        scr = sess.create_script(JS)
        scr.on("message", lambda m, d: print(m.get("payload") if m.get("type") == "send" else ("[ERR] " + str(m.get("stack", "")))))
        scr.load()
        time.sleep(3)
        try: sess.detach()
        except: pass
    except Exception as e:
        print("[ATTACH] 失败:", e)

if __name__ == "__main__":
    main()
