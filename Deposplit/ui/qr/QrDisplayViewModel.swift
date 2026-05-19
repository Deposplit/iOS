import hexagon
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

@Observable
final class QrDisplayViewModel {

    var qrImage: UIImage?
    var pseudonym: String = ""

    private let auth: Identity

    init(auth: Identity) {
        self.auth = auth
    }

    func generate() {
        pseudonym = auth.pseudonym
        let json = QrPayload.encode(
            pseudonym: auth.pseudonym,
            edPublicKey: auth.edPublicKey,
            xPublicKey: auth.xPublicKey
        ) ?? ""
        qrImage = makeQRImage(from: json)
    }

    private func makeQRImage(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
