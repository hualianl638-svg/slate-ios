import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// 把相册里选中的视频复制成沙盒内的临时文件。
/// 直接用 Data 会整段读进内存，4K 素材几百 MB 会爆，所以走 FileRepresentation。
struct Movie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let name = "import-\(UUID().uuidString).\(ext)"
            let dest = URL.documentsDirectory.appending(path: name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Self(url: dest)
        }
    }
}
