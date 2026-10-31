import Foundation
import NativeLabCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AttachmentComposerView: View {
  @ObservedObject var store: AttachmentDraftStore
  let key: AttachmentDraftKey
  let client: LocalServerSessionClient?
  var enabled = true

  @State private var showFiles = false
  @State private var showPhotos = false
  @State private var pickerContext: AttachmentPickerContext?
  @State private var selectionGeneration = UUID()
  @State private var importing = false
  @State private var importTask: Task<Void, Never>?

  private var canPick: Bool {
    enabled && client != nil && !importing
      && store.draft(for: key).items.count < AttachmentUploadPolicy.maximumFilesPerDraft
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Button {
          capturePickerContext()
          showPhotos = true
        } label: {
          Label("Photos", systemImage: "photo")
        }
        .accessibilityIdentifier("attachment-pick-photos")
        .disabled(!canPick)
        Button {
          capturePickerContext()
          showFiles = true
        } label: {
          Label("Files", systemImage: "paperclip")
        }
        .accessibilityIdentifier("attachment-pick-files")
        .disabled(!canPick)
        if importing {
          ProgressView().accessibilityLabel("Reading selected attachments")
          Button("Cancel selection") { importTask?.cancel() }
        }
      }
      .buttonStyle(.bordered)
      Text("Images up to 5 MB · PDFs 20 MB · Text/code 10 MB")
        .font(.caption2).foregroundStyle(.secondary)
      AttachmentDraftListView(
        store: store, key: key, enabled: enabled,
        retry: { id in
          guard let client else { return }
          Task { await store.upload(id, in: key, using: client) }
        })
    }
    .background {
      if let context = pickerContext {
        AttachmentPickerPresentation(
          context: context, showFiles: $showFiles, showPhotos: $showPhotos,
          maximumPhotos: max(
            1, AttachmentUploadPolicy.maximumFilesPerDraft - store.draft(for: key).items.count),
          filesSelected: { captured, result in
            guard captured.generation == selectionGeneration, captured.key == key else { return }
            switch result {
            case .success(let urls): importFiles(urls, context: captured)
            case .failure(let error):
              if (error as NSError).code != NSUserCancelledError {
                store.recordSelectionError(error.localizedDescription, in: captured.key)
              }
            }
          },
          photosSelected: { captured, selected in
            guard captured.generation == selectionGeneration, captured.key == key else { return }
            importPhotos(selected, context: captured)
          }
        ).id(context.generation)
      }
    }
    .onChange(of: key) { _, _ in invalidateSelection() }
    .onChange(of: client.map { ObjectIdentifier($0) }) { _, _ in invalidateSelection() }
    .onDisappear { invalidateSelection() }
  }

  private func capturePickerContext() {
    invalidateSelection()
    guard let client else { return }
    pickerContext = AttachmentPickerContext(
      key: key, client: client, generation: selectionGeneration)
  }

  private func invalidateSelection() {
    importTask?.cancel()
    importTask = nil
    selectionGeneration = UUID()
    importing = false
    pickerContext = nil
    showFiles = false
    showPhotos = false
  }

  private func importPhotos(_ selected: [PhotosPickerItem], context: AttachmentPickerContext) {
    guard !selected.isEmpty else { return }
    let destination = context.key
    let generation = context.generation
    importing = true
    store.recordSelectionError(nil, in: destination)
    importTask = Task {
      defer { if generation == selectionGeneration { importing = false } }
      for photo in selected {
        do {
          try Task.checkCancellation()
          guard let selected = try await photo.loadTransferable(type: PickedAttachmentPhoto.self)
          else {
            throw AttachmentUploadError.unsupportedType
          }
          try Task.checkCancellation()
          guard generation == selectionGeneration else { throw CancellationError() }
          let id = try store.add(selected.file, to: destination)
          Task { await store.upload(id, in: destination, using: context.client) }
        } catch is CancellationError { break } catch {
          guard generation == selectionGeneration else { break }
          store.recordSelectionError(error.localizedDescription, in: destination)
        }
      }
    }
  }

  private func importFiles(_ urls: [URL], context: AttachmentPickerContext) {
    let destination = context.key
    let generation = selectionGeneration
    importing = true
    store.recordSelectionError(nil, in: destination)
    importTask = Task {
      defer { if generation == selectionGeneration { importing = false } }
      let remaining =
        AttachmentUploadPolicy.maximumFilesPerDraft - store.draft(for: destination).items.count
      if urls.count > remaining {
        store.recordSelectionError(
          AttachmentUploadError.draftLimit.localizedDescription, in: destination)
      }
      for url in urls.prefix(remaining) {
        do {
          try Task.checkCancellation()
          let readTask = Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            var result: Result<AttachmentUploadFile, Error>?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(
              readingItemAt: url, options: [], error: &coordinationError
            ) {
              readable in
              result = Result {
                let mime = try? readable.resourceValues(forKeys: [.contentTypeKey]).contentType?
                  .preferredMIMEType
                return try AttachmentUploadFile.read(contentsOf: readable, mediaType: mime)
              }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw CocoaError(.fileReadUnknown) }
            return try result.get()
          }
          let file = try await withTaskCancellationHandler {
            try await readTask.value
          } onCancel: {
            readTask.cancel()
          }
          try Task.checkCancellation()
          guard generation == selectionGeneration else { throw CancellationError() }
          let id = try store.add(file, to: destination)
          Task { await store.upload(id, in: destination, using: context.client) }
        } catch is CancellationError { break } catch {
          store.recordSelectionError(error.localizedDescription, in: destination)
        }
      }
    }
  }
}

private struct AttachmentPickerContext {
  let key: AttachmentDraftKey
  let client: LocalServerSessionClient
  let generation: UUID
}

@MainActor
private struct AttachmentPickerPresentation: View {
  let context: AttachmentPickerContext
  @Binding var showFiles: Bool
  @Binding var showPhotos: Bool
  let maximumPhotos: Int
  let filesSelected: (AttachmentPickerContext, Result<[URL], Error>) -> Void
  let photosSelected: (AttachmentPickerContext, [PhotosPickerItem]) -> Void
  @State private var photos: [PhotosPickerItem] = []

  var body: some View {
    Color.clear.frame(width: 0, height: 0)
      .fileImporter(
        isPresented: $showFiles, allowedContentTypes: [.data], allowsMultipleSelection: true
      ) {
        filesSelected(context, $0)
      }
      .photosPicker(
        isPresented: $showPhotos, selection: $photos, maxSelectionCount: maximumPhotos,
        matching: .images, preferredItemEncoding: .compatible
      )
      .onChange(of: photos) { _, selected in
        guard !selected.isEmpty else { return }
        photos = []
        photosSelected(context, selected)
      }
  }
}

private struct PickedAttachmentPhoto: Transferable {
  let file: AttachmentUploadFile

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { received in
      // FileRepresentation avoids loading an unbounded photo as Data before checking its size.
      PickedAttachmentPhoto(file: try AttachmentUploadFile.read(contentsOf: received.file))
    }
  }
}

@MainActor
struct AttachmentDraftListView: View {
  @ObservedObject var store: AttachmentDraftStore
  let key: AttachmentDraftKey
  var enabled = true
  let retry: (UUID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(store.draft(for: key).items) { item in
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .top) {
            Image(systemName: item.file.mediaType.hasPrefix("image/") ? "photo" : "doc")
              .accessibilityHidden(true)
            Text(item.file.filename).font(.subheadline).lineLimit(2)
            Spacer(minLength: 8)
            if case .uploading = item.state {
              Button("Cancel") { store.cancelUpload(item.id, in: key) }
                .accessibilityLabel("Cancel upload \(item.file.filename)")
                .accessibilityIdentifier("attachment-cancel-\(item.file.filename)")
            } else {
              Button {
                store.remove(item.id, from: key)
              } label: {
                Image(systemName: "xmark.circle")
              }
              .accessibilityLabel("Remove \(item.file.filename)")
              .accessibilityIdentifier("attachment-remove-\(item.file.filename)")
              .disabled(!enabled || store.isLocked(item.id, in: key))
            }
          }
          switch item.state {
          case .staged:
            Text("Ready to upload").font(.caption)
            retryButton(item)
          case .uploading(let progress):
            ProgressView(value: progress).accessibilityLabel("Uploading \(item.file.filename)")
            Text(progress >= 1 ? "Waiting for confirmation…" : "Uploading \(Int(progress * 100))%")
              .font(.caption)
          case .uploaded:
            Label("Uploaded · Ready to send", systemImage: "checkmark.circle").font(.caption)
          case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
            retryButton(item)
          case .uncertain(let message):
            Text(message).font(.caption).foregroundStyle(.orange)
              .accessibilityIdentifier("attachment-uncertain-\(item.file.filename)")
          }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
      }
      if let error = store.draft(for: key).selectionError {
        Text(error).font(.caption).foregroundStyle(.red)
          .accessibilityIdentifier("attachment-selection-error")
      }
    }
  }

  private func retryButton(_ item: AttachmentDraftItem) -> some View {
    Button("Upload") { retry(item.id) }
      .font(.caption)
      .accessibilityLabel("Upload \(item.file.filename)")
      .accessibilityIdentifier("attachment-retry-\(item.file.filename)")
      .disabled(!enabled || store.isLocked(item.id, in: key))
  }
}

/// Root can present this only for --ui-testing --ui-test-upload-fixtures. It never creates a client.
@MainActor
struct AttachmentUploadFixtureView: View {
  @StateObject private var store = AttachmentDraftStore()
  @State private var session = "A"
  @State private var texts: [String: String] = [:]
  @State private var sends = 0
  @State private var failure = false

  private var key: AttachmentDraftKey {
    AttachmentDraftKey(scope: "offline-upload-fixture", sessionID: session)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Offline attachment fixtures").font(.headline)
        Picker("Session", selection: $session) {
          Text("A").tag("A")
          Text("B").tag("B")
        }.pickerStyle(.segmented).accessibilityIdentifier("upload-fixture-session")
        TextField(
          "Message", text: Binding(get: { texts[session] ?? "" }, set: { texts[session] = $0 })
        )
        .accessibilityIdentifier("upload-fixture-text")
        HStack {
          Button("Add file") { addFixture("notes.txt", mode: "ready") }
            .accessibilityIdentifier("upload-fixture-add")
          Button("Uncertain upload") { addFixture("uncertain.txt", mode: "uncertain") }
            .accessibilityIdentifier("upload-fixture-uncertain")
          Button("Slow upload") { addFixture("slow.txt", mode: "slow") }
            .accessibilityIdentifier("upload-fixture-slow")
        }.buttonStyle(.bordered)
        Toggle("Reject send", isOn: $failure).accessibilityIdentifier("upload-fixture-reject")
        AttachmentDraftListView(store: store, key: key, retry: { _ in })
        Button("Send") {
          guard let batch = try? store.beginSubmission(in: key) else { return }
          sends += 1
          store.finishSubmission(batch, outcome: failure ? .rejected : .accepted)
          if !failure { texts[session] = "" }
        }
        .disabled(
          !store.canSubmit(in: key)
            || (!store.draft(for: key).hasAttachments && (texts[session] ?? "").isEmpty)
        )
        .accessibilityIdentifier("upload-fixture-send")
        Text("Send attempts: \(sends)").accessibilityIdentifier("upload-fixture-attempts")
      }.padding()
    }
  }

  private func addFixture(_ name: String, mode: String) {
    let destination = key
    guard let file = try? AttachmentUploadFile(filename: name, data: Data("offline fixture".utf8)),
      let id = try? store.add(file, to: destination)
    else { return }
    Task {
      await store.upload(id, in: destination) { file, sessionID, progress in
        if mode == "uncertain" { throw AttachmentUploadError.uploadUncertain }
        if mode == "slow" {
          progress(0.4)
          do { try await Task.sleep(for: .seconds(30)) } catch {
            throw AttachmentUploadError.uploadUncertain
          }
        }
        return UploadedAttachment(
          serverURL: URL(string: "https://fixture.invalid")!, sessionID: sessionID,
          id: "fixture_\(UUID().uuidString)", filename: file.filename, isImage: false)
      }
    }
  }
}
