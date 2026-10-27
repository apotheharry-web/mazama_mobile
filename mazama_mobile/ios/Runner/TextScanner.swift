// The iOS half of lib/text_scanner.dart's "mazama/text_scanner" MethodChannel ('scanLabel' method) - Apple's
// own UIImagePickerController for the camera capture and the Vision framework's VNRecognizeTextRequest for
// the OCR itself, both already part of iOS. No CocoaPods dependency needed for either half. AppDelegate.swift
// registers it on the channel.
//
// Returns exactly what text_scanner.dart's scanLabel expects: `result(nil)` when the worker cancels out of the
// camera screen (text_scanner.dart turns that into ScanCancelled - not an error), `result([String])` - one
// entry per recognized line, in Vision's own best-effort reading order - on a successful capture, or a
// FlutterError for anything that actually went wrong (no camera on this device, Vision itself erroring). The
// real fuzzy matching against inventory - mazama_sales' own ocr.find_ids/ocr.closest - happens server-side
// (see scan_match_client.dart); this file's only job is handing those lines over exactly as read, never trying
// to pre-filter, clean up, or guess at a lot number itself.
import Flutter
import UIKit
import Vision

final class TextScanner: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private weak var presentingController: UIViewController?
    private var pendingResult: FlutterResult?

    init(channel: FlutterMethodChannel, presentingController: UIViewController) {
        self.presentingController = presentingController
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            guard call.method == "scanLabel" else {
                result(FlutterMethodNotImplemented)
                return
            }
            self?.scanLabel(result: result)
        }
    }

    private func scanLabel(result: @escaping FlutterResult) {
        // One scan at a time - cart_page.dart's own Scan button is already disabled while a dialog from the
        // previous one is still up, but this guards the native side too rather than trusting the Dart side
        // alone to never call scanLabel twice in a row.
        guard pendingResult == nil else {
            result(FlutterError(code: "scan_in_progress", message: "A scan is already in progress.", details: nil))
            return
        }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            result(FlutterError(code: "no_camera", message: "This device has no camera.", details: nil))
            return
        }
        guard let presenter = presentingController else {
            result(FlutterError(code: "no_controller", message: "No screen to present the camera from.", details: nil))
            return
        }
        pendingResult = result
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        // No crop/edit step a worker could use to fiddle with the photo before it's read - the same "read it
        // exactly as the camera saw it" reasoning the server's own Tesseract path already has for an uploaded
        // photo.
        picker.allowsEditing = false
        presenter.present(picker, animated: true)
    }

    private func complete(_ value: Any?) {
        guard let result = pendingResult else { return } // already completed (or never started) - ignore
        pendingResult = nil
        result(value)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage, let cgImage = image.cgImage else {
            complete(FlutterError(code: "no_image", message: "Could not read the captured photo.", details: nil))
            return
        }
        recognizeText(in: cgImage, orientation: cgOrientation(from: image.imageOrientation))
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        complete(nil) // text_scanner.dart's own contract: nil means ScanCancelled, not an error
    }

    /// Runs Vision's own text recognizer on the just-captured photo, off the main thread (Vision's own
    /// documented recommendation for .accurate - the main thread would otherwise hang for however long
    /// recognition takes, which for a label-sized photo is well under a second but still not something to do
    /// synchronously). usesLanguageCorrection is off on purpose: a lot number like "579b4701" is not a
    /// dictionary word, and Vision's own spell-correction would happily "fix" it into something that reads
    /// better but matches nothing in inventory.
    private func recognizeText(in cgImage: CGImage, orientation: CGImagePropertyOrientation) {
        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { self.complete(FlutterError(code: "ocr_failed", message: error.localizedDescription, details: nil)) }
                return
            }
            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            // topCandidates(1) - Vision's single best reading of each line. scan_match_client.dart sends every
            // line on to the server's own fuzzy matcher, which already tolerates a misread character or two
            // (mazama_sales' ocr.find_ids), so there's no reason to also carry Vision's lower-confidence
            // alternates along with it.
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            DispatchQueue.main.async { self.complete(lines) }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async { self.complete(FlutterError(code: "ocr_failed", message: error.localizedDescription, details: nil)) }
            }
        }
    }
}

/// UIImage.Orientation (what the camera/photo library hands back) and Vision's own CGImagePropertyOrientation
/// are both "which way is up" for the same photo, just numbered differently - Vision needs the
/// CGImagePropertyOrientation form to read a photo the camera captured sideways (as a phone held normally for
/// a landscape-oriented label often is) the right way up before it ever looks for text in it.
private func cgOrientation(from orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
    switch orientation {
    case .up: return .up
    case .down: return .down
    case .left: return .left
    case .right: return .right
    case .upMirrored: return .upMirrored
    case .downMirrored: return .downMirrored
    case .leftMirrored: return .leftMirrored
    case .rightMirrored: return .rightMirrored
    @unknown default: return .up
    }
}
