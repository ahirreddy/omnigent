import CoreImage
import CoreImage.CIFilterBuiltins
public import SwiftUI

/// A pairing code as a QR image, for the Mac's Settings › Phone.
public struct PairingQRCodeView: View {
  private let code: PairingCode
  private let image: CGImage?

  /// Creates the view.
  /// - Parameter code: The code to show.
  public init(code: PairingCode) {
    self.code = code
    image = Self.render(code.text)
  }

  /// The QR code on a white tile, so it scans in dark mode too.
  public var body: some View {
    Group {
      if let image {
        Image(decorative: image, scale: 1)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
      } else {
        Label("The code could not be drawn.", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .background(.white, in: RoundedRectangle(cornerRadius: 12))
    .accessibilityElement()
    .accessibilityLabel("Pairing code for \(ServerIdentity.hostLabel(code.serverURL))")
    .accessibilityIdentifier("pairing.qr-code")
  }

  /// The QR image for `text`, at one pixel per module; `nil` when Core Image can't encode it.
  /// - Parameter text: The text.
  /// - Returns: The image.
  static func render(_ text: String) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    return CIContext().createCGImage(output, from: output.extent)
  }
}

/// Asks before connecting to a scanned server: the host, prominently, and the full URL. A
/// pairing code is never trusted on its own.
public struct PairingConfirmationView: View {
  private let confirmation: PairingConfirmation
  private let connect: @MainActor () -> Void
  private let cancel: @MainActor () -> Void

  /// Creates the view.
  /// - Parameters:
  ///   - confirmation: The validated code.
  ///   - connect: Connects; the server then asks the user to sign in.
  ///   - cancel: Leaves without connecting.
  public init(
    confirmation: PairingConfirmation, connect: @escaping @MainActor () -> Void,
    cancel: @escaping @MainActor () -> Void
  ) {
    self.confirmation = confirmation
    self.connect = connect
    self.cancel = cancel
  }

  /// The confirmation.
  public var body: some View {
    AuthCard(
      systemImage: "qrcode.viewfinder", title: "Connect to this server?",
      subtitle: "Only connect to servers you trust. You'll sign in next."
    ) {
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: confirmation.host)
          .font(.title3.weight(.semibold))
          .lineLimit(2)
          .accessibilityIdentifier("pairing.host")
        Text(verbatim: ServerText.escaped(confirmation.serverURL, limit: 200))
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .accessibilityIdentifier("pairing.url")
      }
      if confirmation.isLoopback {
        Label(
          "This address points to the device it is opened on, so it may not reach your computer.",
          systemImage: "exclamationmark.triangle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("pairing.loopback-warning")
      }
    } buttons: {
      AuthButton(title: "Cancel", kind: .cancel, identifier: "pairing.cancel", action: cancel)
      AuthButton(title: "Connect", kind: .primary, identifier: "pairing.connect", action: connect)
    }
  }
}

#if os(iOS)
  import Vision
  import VisionKit

  /// Scans a pairing code from the Mac's Settings › Phone with the camera, then confirms the
  /// server before connecting. Where the camera can't scan (the Simulator, or no permission), the
  /// code's text can be pasted instead.
  public struct PairingScannerSheet: View {
    private let validator: ServerURLValidator
    private let connect: @MainActor (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: PairingConfirmation?
    @State private var problem: String?
    @State private var pasted = ""

    /// Creates the sheet.
    /// - Parameters:
    ///   - validator: The core's URL check.
    ///   - connect: Connects to the confirmed, normalized server URL.
    public init(validator: ServerURLValidator, connect: @escaping @MainActor (String) -> Void) {
      self.validator = validator
      self.connect = connect
    }

    /// The sheet.
    public var body: some View {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if let confirmation {
              PairingConfirmationView(
                confirmation: confirmation,
                connect: {
                  connect(confirmation.serverURL)
                  dismiss()
                },
                cancel: { self.confirmation = nil })
            } else {
              scanner
              pasteField
            }
            if let problem {
              Label(problem, systemImage: "exclamationmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .accessibilityIdentifier("pairing.error")
            }
          }
          .padding()
        }
        .navigationTitle("Scan Pairing Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
              .accessibilityIdentifier("pairing.close")
          }
        }
      }
      .accessibilityIdentifier("pairing.scanner")
    }

    @ViewBuilder private var scanner: some View {
      if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
        Text("On your Mac, open Omnigent Settings \u{203A} Phone and point the camera at the code.")
          .font(.callout)
          .foregroundStyle(.secondary)
        PairingCameraView(onCode: handle, onError: { problem = $0 })
          .frame(height: 320)
          .clipShape(RoundedRectangle(cornerRadius: 16))
          .accessibilityIdentifier("pairing.camera")
      } else {
        Label(
          DataScannerViewController.isSupported
            ? "Allow camera access in Settings to scan, or paste the code below."
            : "This device can't scan codes. Paste the code from your Mac below.",
          systemImage: "camera"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("pairing.camera-unavailable")
      }
    }

    private var pasteField: some View {
      VStack(alignment: .leading, spacing: 8) {
        TextField("omnigent:pair?…", text: $pasted)
          .textFieldStyle(.roundedBorder)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .submitLabel(.go)
          .onSubmit { handle(pasted) }
          .accessibilityLabel("Pairing code")
          .accessibilityIdentifier("pairing.paste-field")
        Button("Use Code") { handle(pasted) }
          .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
          .accessibilityIdentifier("pairing.use-code")
      }
    }

    private func handle(_ text: String) {
      do {
        confirmation = try PairingCode(parsing: text).confirmation(validator: validator)
        problem = nil
      } catch {
        problem = error.message
      }
    }
  }

  /// `DataScannerViewController` for QR codes; reports the first code it recognizes.
  struct PairingCameraView: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void
    let onError: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
      let scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
        recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
        isHighlightingEnabled: true)
      scanner.delegate = context.coordinator
      return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
      context.coordinator.onCode = onCode
      guard !scanner.isScanning else { return }
      do {
        try scanner.startScanning()
      } catch {
        onError("The camera could not start: \(error.localizedDescription)")
      }
    }

    static func dismantleUIViewController(
      _ scanner: DataScannerViewController, coordinator: Coordinator
    ) {
      scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
      var onCode: @MainActor (String) -> Void

      init(onCode: @escaping @MainActor (String) -> Void) {
        self.onCode = onCode
      }

      func dataScanner(
        _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
        allItems: [RecognizedItem]
      ) {
        for item in addedItems {
          if case .barcode(let barcode) = item, let text = barcode.payloadStringValue {
            onCode(text)
            return
          }
        }
      }
    }
  }
#endif
