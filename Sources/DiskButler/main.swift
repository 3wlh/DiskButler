import Foundation

// 后台模式先于 GUI 判断：launchd 调用的也是这一份二进制
if CommandLine.arguments.contains("--daemon") || CommandLine.arguments.contains("--login") {
    Daemon.run(CommandLine.arguments)
    exit(0)
}

DiskButlerApp.main()
