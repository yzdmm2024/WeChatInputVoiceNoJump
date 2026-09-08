// 将 base64 deb 写入设备
// After base64 paste:
// data.decodedData = [[NSData alloc] initWithBase64EncodedString:base64String options:0];
// [data writeToFile:@"/var/mobile/com.yzdmm.wechatvoicenojump_1.0.0-1+debug_iphoneos-arm64.deb" atomically:YES];

var base64 = "REPLACE_ME";
console.log("Writing deb to /var/mobile/com.yzdmm.wechatvoicenojump.deb...");

var data = ObjC.classes.NSData.dataWithBase64EncodedString_options_(base64, 0);
var success = data.writeToFile_atomically_("/var/mobile/com.yzdmm.wechatvoicenojump.deb", YES);

console.log("Write success: " + success);

// 验证文件大小
var fm = ObjC.classes.NSFileManager.defaultManager();
var attrs = fm.attributesOfItemAtPath_error_("/var/mobile/com.yzdmm.wechatvoicenojump.deb", NULL);
if (attrs) {
    console.log("File size: " + attrs.NSFileSize + " bytes");
}

// 显示 dpkg 安装命令
console.log("\nTo install, execute:");
console.log("dpkg -i /var/mobile/com.yzdmm.wechatvoicenojump.deb");
console.log("killall -9 SpringBoard");
