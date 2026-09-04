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
    private let relaySettings: any RelaySettings

    init(auth: Identity, relaySettings: any RelaySettings) {
        self.auth = auth
        self.relaySettings = relaySettings
    }

    func generate() {
        pseudonym = auth.pseudonym
        // The QR is the one path by which a broken identity reaches another person's phone, and on
        // a restored device the public keys can outlive the private ones — so a code encoded here
        // would scan cleanly and name an identity nobody can use. The launch gate should have
        // caught that already; this is the second lock.
        guard auth.integrity == .intact, let verifyKey = auth.verifyKey, let encKey = auth.encKey else {
            qrImage = nil
            return
        }
        let json = QrPayload.encode(
            pseudonym: auth.pseudonym,
            verifyKey: verifyKey,
            encKey: encKey,
            cipherSuite: .current,
            relayBaseUrl: relaySettings.defaultRelayBaseURL()
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
