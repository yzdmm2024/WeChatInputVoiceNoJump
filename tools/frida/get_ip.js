// 读取设备所有 IPv4 接口地址(排除 lo)，用于判断 SSH 可达性
'use strict';
function run() {
  const libc = Module.findExportByName(null, 'getifaddrs');
  const freeifaddrs = Module.findExportByName(null, 'freeifaddrs');
  if (!libc) { console.log('NO_GETIFADDRS'); return; }
  const ps = Process.pointerSize;
  const ifa = Memory.alloc(ps);
  const ret = new NativeFunction(libc, 'int', ['pointer'])(ifa);
  if (ret !== 0) { console.log('GETIFADDRS_FAIL'); return; }
  let p = ifa.readPointer();
  const AF_INET = 2;
  const out = [];
  while (!p.isNull()) {
    const ifa_name = p.add(ps).readPointer();
    let name = '';
    try { name = ifa_name.readUtf8String(); } catch (e) { name = '?'; }
    const ifa_addr = p.add(ps*3).readPointer();
    if (!ifa_addr.isNull()) {
      const family = ifa_addr.add(0).readU16();
      if (family === AF_INET) {
        const addr = ifa_addr.add(4).readU32();
        const b0 = addr & 0xff, b1 = (addr>>8)&0xff, b2=(addr>>16)&0xff, b3=(addr>>24)&0xff;
        const ip = b0 + '.' + b1 + '.' + b2 + '.' + b3;
        if (name !== 'lo0' && !(b0===127)) out.push(name + '=' + ip);
      }
    }
    p = p.readPointer();
  }
  if (freeifaddrs) new NativeFunction(freeifaddrs, 'void', ['pointer'])(ifa.readPointer());
  console.log('IP_RESULT ' + JSON.stringify(out));
}
run();
