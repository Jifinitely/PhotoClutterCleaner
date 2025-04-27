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
    @Published var errorMessage: String?
    @Published var isProcessing = false
    
    private let imageManager = PHCachingImageManager()
    private var processingQueue = DispatchQueue(label: "com.photocluttercleaner.processing", qos: .userInitiated)
    
    private init() {
        imageManager.allowsCachingHighQualityImages = false
    }
    
    func requestAuthorization() {
        PHPhotoLibrary.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self?.authorized = true
                    self?.findDuplicates()
                case .denied, .restricted:
                    self?.authorized = false
                    self?.errorMessage = "Photo library access is required to find duplicates. Please enable access in Settings."
                case .notDetermined:
                    self?.authorized = false
                case .limited:
                    self?.authorized = true
                    self?.findDuplicates()
                @unknown default:
                    self?.authorized = false
                }
            }
        }
    }
    
    func findDuplicates() {
        guard !isProcessing else { return }
        isProcessing = true
        errorMessage = nil
        
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            
            let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
            var hashes: [String: [PHAsset]] = [:]
            let requestOptions = PHImageRequestOptions()
            requestOptions.deliveryMode = .fastFormat
            requestOptions.isNetworkAccessAllowed = false
            requestOptions.isSynchronous = false
            
            let group = DispatchGroup()
            let semaphore = DispatchSemaphore(value: 5) // Limit concurrent requests
            
            assets.enumerateObjects { asset, _, stop in
                guard !self.isProcessing else {
                    stop.pointee = true
                    return
                }
                
                semaphore.wait()
                group.enter()
                
                self.imageManager.requestImageDataAndOrientation(for: asset, options: requestOptions) { data, _, _, _ in
                    defer {
                        semaphore.signal()
                        group.leave()
                    }
                    
                    guard let data = data else { return }
                    let hash = data.sha256()
                    DispatchQueue.main.async {
                        hashes[hash, default: []].append(asset)
                    }
                }
            }
            
            group.notify(queue: .main) {
                self.duplicates = hashes.values.filter { $0.count > 1 }
                self.isProcessing = false
            }
        }
    }
    
    func deleteAssets(_ assets: [PHAsset], completion: @escaping (Bool, String?) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }) { success, error in
            DispatchQueue.main.async {
                if success {
                    self.findDuplicates()
                    completion(true, nil)
                } else {
                    completion(false, error?.localizedDescription ?? "Failed to delete photos")
                }
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
    
    func cleanJunk(completion: @escaping (Bool, String?) -> Void) {
        processingQueue.async {
            let tmp = FileManager.default.temporaryDirectory
            do {
                let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil, options: [])
                for url in files {
                    try FileManager.default.removeItem(at: url)
                }
                DispatchQueue.main.async {
                    completion(true, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
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
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationView {
            Group {
                if !manager.authorized {
                    VStack(spacing: 20) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text("Photo Library Access Required")
                            .font(.headline)
                        Text("Please enable access to your photo library in Settings to find duplicate photos.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else if manager.isProcessing {
                    ProgressView("Finding duplicates...")
                        .progressViewStyle(.circular)
                } else if manager.duplicates.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 60))
                            .foregroundColor(.green)
                        Text("No Duplicates Found")
                            .font(.headline)
                        Text("Your photo library is clean!")
                            .foregroundColor(.secondary)
                    }
                } else {
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
                }
            }
            .navigationTitle("Duplicates")
            .alert("Delete this set?", isPresented: $showAlert) {
                Button("Delete All", role: .destructive) {
                    manager.deleteAssets(toDelete) { success, error in
                        if !success {
                            errorMessage = error ?? "Failed to delete photos"
                            showError = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
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
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("Junk Files")
                        .font(.title2)
                    Text("\(String(format: "%.2f", manager.junkSize()/1e6)) MB")
                        .font(.title)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 20)
                
                Button(action: {
                    cleaning = true
                    manager.cleanJunk { success, error in
                        cleaning = false
                        if !success {
                            errorMessage = error ?? "Failed to clean junk files"
                            showError = true
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: "trash.circle.fill")
                            .font(.title2)
                        Text("Clean Junk")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(cleaning ? Color.gray : Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(cleaning)
                
                if cleaning {
                    ProgressView()
                        .padding(.top)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Junk Cleaner")
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }
}

struct PerformanceView: View {
    @State private var memoryUsage = 0.0
    @State private var diskSpace = (free: 0.0, total: 0.0)
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                PerformanceCard(
                    title: "Memory Usage",
                    value: String(format: "%.2f GB", memoryUsage),
                    icon: "memorychip",
                    color: .blue
                )
                
                PerformanceCard(
                    title: "Free Space",
                    value: String(format: "%.2f GB", diskSpace.free),
                    icon: "internaldrive",
                    color: .green
                )
                
                PerformanceCard(
                    title: "Total Space",
                    value: String(format: "%.2f GB", diskSpace.total),
                    icon: "harddisk",
                    color: .gray
                )
                
                Spacer()
            }
            .padding()
            .navigationTitle("Performance")
            .onReceive(timer) { _ in
                memoryUsage = PerformanceChecker.memoryUsage()
                diskSpace = PerformanceChecker.diskSpace()
            }
        }
    }
}

struct PerformanceCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(color)
                .frame(width: 40)
            
            VStack(alignment: .leading) {
                Text(title)
                    .font(.headline)
                Text(value)
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(10)
        .shadow(radius: 2)
    }
}

/* In Xcode: remove default SwiftUI files, add this file, bridging header, Info.plist, then build & run. */
