import SwiftUI
import Photos
import CommonCrypto
import Darwin

@main
struct PhotoClutterCleanerApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(PhotoLibraryManager.shared)
        }
    }
}

// MARK: - Photo Library Manager
class PhotoLibraryManager: ObservableObject {
    static let shared = PhotoLibraryManager()
    @Published var duplicates: [[PHAsset]] = []
    @Published var authorized = false

    private init() {}

    func requestAuthorization() {
        PHPhotoLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                self.authorized = (status == .authorized)
                if self.authorized { self.findDuplicates() }
            }
        }
    }

    func findDuplicates() {
        DispatchQueue.global(qos: .userInitiated).async {
            let assets = PHAsset.fetchAssets(with: .image, options: nil)
            var hashes: [String: [PHAsset]] = [:]
            let manager = PHCachingImageManager()
            let opts = PHImageRequestOptions()
            opts.isSynchronous = true
            opts.deliveryMode = .fastFormat

            assets.enumerateObjects { asset, _, _ in
                manager.requestImageDataAndOrientation(for: asset, options: opts) { data, _, _, _ in
                    guard let data = data else { return }
                    let hash = data.sha256()
                    DispatchQueue.main.async {
                        hashes[hash, default: []].append(asset)
                    }
                }
            }
            DispatchQueue.main.async {
                self.duplicates = hashes.values.filter { $0.count > 1 }
            }
        }
    }

    func deleteAssets(_ assets: [PHAsset], completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }) { success, _ in
            DispatchQueue.main.async {
                if success { self.findDuplicates() }
                completion(success)
            }
        }
    }

    func junkSize() -> Double {
        let tmp = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.fileSizeKey], options: [])) ?? []
        return files.reduce(0) { acc, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return acc + Double(size)
        }
    }

    func cleanJunk(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FileManager.default.temporaryDirectory
            let files = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil, options: [])) ?? []
            for url in files { try? FileManager.default.removeItem(at: url) }
            DispatchQueue.main.async { completion() }
        }
    }
}

// MARK: - Helpers
extension Data {
    func sha256() -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(self.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

struct PerformanceChecker {
    static func diskSpace() -> (free: Double, total: Double) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let free = attrs[.systemFreeSize] as? NSNumber,
              let total = attrs[.systemSize] as? NSNumber else { return (0,0) }
        return (free.doubleValue/1e9, total.doubleValue/1e9)
    }
    static func memoryUsage() -> Double {
        var info = mach_task_basic_info()
        var cnt = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let _ = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &cnt)
            }
        }
        return Double(info.resident_size)/1e9
    }
}

// MARK: - Views

struct AnimatedLabel: View {
    @Binding var selection: Int
    let index: Int
    let systemImage: String
    let title: String

    var body: some View {
        VStack {
            Image(systemName: systemImage)
                .font(.title2)
                .scaleEffect(selection == index ? 1.2 : 1)
                .animation(.spring(), value: selection)
            Text(title).font(.caption)
        }
    }
}

struct MainView: View {
    @EnvironmentObject var manager: PhotoLibraryManager
    @State private var sel = 0

    var body: some View {
        TabView(selection: $sel) {
            DuplicatePhotosView()
                .tabItem { AnimatedLabel(selection: $sel, index: 0, systemImage: "photo.on.rectangle.angled", title: "Duplicates") }
                .tag(0)
            JunkCleanerView()
                .tabItem { AnimatedLabel(selection: $sel, index: 1, systemImage: "trash", title: "Junk") }
                .tag(1)
            PerformanceView()
                .tabItem { AnimatedLabel(selection: $sel, index: 2, systemImage: "speedometer", title: "Performance") }
                .tag(2)
        }
        .onAppear { manager.requestAuthorization() }
    }
}

struct DuplicatePhotosView: View {
    @EnvironmentObject var manager: PhotoLibraryManager
    @State private var showAlert = false
    @State private var toDelete: [PHAsset] = []

    var body: some View {
        NavigationView {
            List {
                ForEach(manager.duplicates.indices, id: \.self) { i in
                    Section("Set \(i+1)") {
                        ForEach(manager.duplicates[i], id: \.localIdentifier) { asset in
                            PhotoRow(asset: asset)
                                .onTapGesture {
                                    toDelete = manager.duplicates[i]
                                    showAlert = true
                                }
                        }
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("Duplicates")
            .alert(isPresented: $showAlert) {
                Alert(
                    title: Text("Delete this set?"),
                    primaryButton: .destructive(Text("Delete All")) { manager.deleteAssets(toDelete) { _ in } },
                    secondaryButton: .cancel()
                )
            }
        }
    }
}

struct PhotoRow: View {
    let asset: PHAsset
    @State private var img: UIImage? = nil

    var body: some View {
        HStack {
            if let ui = img {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 40, height: 40)
                    .onAppear {
                        PHCachingImageManager().requestImage(for: asset, targetSize: CGSize(width: 40, height: 40), contentMode: .aspectFill, options: nil) { i, _ in img = i }
                    }
            }
            Text(asset.localIdentifier).lineLimit(1)
        }
    }
}

struct JunkCleanerView: View {
    @EnvironmentObject var manager: PhotoLibraryManager
    @State private var cleaning = false

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text("Junk: \(String(format: "%.2f", manager.junkSize()/1e6)) MB")
                    .font(.title2)
                Button(action: {
                    cleaning = true
                    manager.cleanJunk { cleaning = false }
                }) {
                    Label("Clean Junk", systemImage: "trash.circle.fill")
                        .padding()
                        .background(Capsule().fill(cleaning ? Color.gray : Color.red))
                        .foregroundColor(.white)
                }
                .disabled(cleaning)
                Spacer()
            }
            .padding()
            .navigationTitle("Junk Cleaner")
        }
    }
}

struct PerformanceView: View {
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                let (f, t) = PerformanceChecker.diskSpace()
                Text("Disk Free: \(String(format: "%.2f", f)) GB")
                Text("Disk Total: \(String(format: "%.2f", t)) GB")
                Text("Memory Used: \(String(format: "%.2f", PerformanceChecker.memoryUsage())) GB")
                Spacer()
            }
            .font(.headline)
            .padding()
            .navigationTitle("Performance")
        }
    }
}

/* In Xcode: remove default SwiftUI files, add this file, bridging header, Info.plist, then build & run. */
