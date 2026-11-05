// ScanImage.swift
// 遍历已加载镜像的 __cstring，按关键词过滤。用于定位私有 XPC 服务名。
import Foundation
import MachO
import ObjectiveC.runtime

func scanImage(_ nameFilter: String, keywords: [String]) {
    for i in 0..<_dyld_image_count() {
        guard let ptr = _dyld_get_image_name(i) else { continue }
        let path = String(cString: ptr)
        guard path.contains(nameFilter) else { continue }
        print("镜像: \(path)")
        let header = _dyld_get_image_header(i)!
        let slide = _dyld_get_image_vmaddr_slide(i)
        var cmd = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        var found = 0
        for _ in 0..<header.pointee.ncmds {
            let c = cmd.load(as: load_command.self)
            if c.cmd == LC_SEGMENT_64 {
                let seg = cmd.load(as: segment_command_64.self)
                var sect = cmd.advanced(by: MemoryLayout<segment_command_64>.size)
                for _ in 0..<seg.nsects {
                    let s = sect.load(as: section_64.self)
                    let sectName = withUnsafeBytes(of: s.sectname) { raw in
                        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                    }
                    if sectName == "__cstring", s.size > 0 {
                        let addr = Int(UInt(s.addr) + UInt(bitPattern: slide))
                        guard let base = UnsafeRawPointer(bitPattern: addr) else { break }
                        var p = 0
                        let chars = base.bindMemory(to: CChar.self, capacity: Int(s.size))
                        while p < Int(s.size) {
                            let str = String(cString: chars + p)
                            let low = str.lowercased()
                            if str.count > 3, keywords.contains(where: { low.contains($0) }) {
                                print("  \(str)")
                                found += 1
                            }
                            p += str.utf8.count + 1
                        }
                    }
                    sect = sect.advanced(by: MemoryLayout<section_64>.size)
                }
            }
            cmd = cmd.advanced(by: Int(c.cmdsize))
        }
        print("  共 \(found) 条命中")
    }
}

let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "CoreDisplay"
scanImage(filter, keywords: ["proxy", "xpc", "virtualdisplay", "spawn", "com.apple.d", "plugin"])
