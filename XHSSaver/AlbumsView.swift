import AVKit
import Photos
import SwiftUI

/// 「相册」标签页：整理用户自己建的相册。搜索、筛选、多选都在底部
struct AlbumsView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case handwritten = "手写的名字"
        case duplicates = "可能重复"
        var id: String { rawValue }
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var access: Bool?
    @State private var infos: [Albums.Info] = []
    @State private var query = ""
    @State private var filter = Filter.all
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var askMerge = false
    @State private var working = false
    @State private var failure: String?
    /// 第一次读完之前是 false（显示转圈）
    @State private var loaded = false
    /// 每次重新读加一：读的时候界面照常能用，回来时只认最后一次的结果
    @State private var loadRound = 0
    /// 「可能重复」的分组（在后台算）；nil = 还没算出来
    @State private var allGroups: [(key: String, albums: [Albums.Info])]?

    /// 重新读相册列表。在后台读，读完和现在显示的一样就什么都不动（列表不闪、不重排）
    private func reload() async {
        loadRound += 1
        let mine = loadRound
        let ok = await PhotoSaver.hasFullAccess()
        let fresh = ok ? await Albums.infos() : []
        guard mine == loadRound else { return }
        access = ok
        loaded = true
        let same = fresh.count == infos.count && zip(fresh, infos).allSatisfy {
            $0.id == $1.id && $0.title == $1.title && $0.count == $1.count
        }
        if !same {
            infos = fresh
            let ids = Set(fresh.map(\.id))
            selected = selected.filter { ids.contains($0) }
            allGroups = nil
        }
        if filter == .duplicates { await findGroups() }
    }

    private func findGroups() async {
        guard allGroups == nil else { return }
        let mine = loadRound
        let found = await Albums.duplicateGroups(infos)
        if mine == loadRound { allGroups = found }
    }

    private var shown: [Albums.Info] {
        var list = infos
        if filter == .handwritten { list = list.filter { !$0.ruled } }
        let parts = Albums.queryParts(query)
        if !parts.isEmpty {
            list = list.filter { info in parts.allSatisfy { info.key.contains($0) } }
        }
        return list
    }

    private var groups: [(key: String, albums: [Albums.Info])] {
        let parts = Albums.queryParts(query)
        guard !parts.isEmpty else { return allGroups ?? [] }
        return (allGroups ?? []).filter { g in
            g.albums.contains { info in parts.allSatisfy { info.key.contains($0) } }
        }
    }

    private var picked: [Albums.Info] { infos.filter { selected.contains($0.id) } }

    @ViewBuilder
    private func row(_ info: Albums.Info) -> some View {
        if selecting {
            Button {
                if selected.contains(info.id) { selected.remove(info.id) } else { selected.insert(info.id) }
            } label: {
                AlbumRow(title: info.title, count: info.count, cover: nil, album: info.album) {
                    Image(systemName: selected.contains(info.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(info.id) ? Color.accentColor : Color.secondary)
                }
            }
            .foregroundStyle(.primary)
        } else {
            NavigationLink {
                AlbumDetailView(album: info.album)
            } label: {
                AlbumRow(title: info.title, count: info.count, cover: nil, album: info.album) {
                    Text(info.ruled ? "按规则" : "手写")
                        .font(.caption)
                        .foregroundStyle(info.ruled ? Color.green : Color.secondary)
                }
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if selecting {
                Button("合并选中的 \(selected.count) 个相册") { askMerge = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(selected.count < 2 || working)
                    .accessibilityIdentifier("albums-merge")
            } else {
                Picker("筛选", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("albums-filter")
            }
            HStack(spacing: 10) {
                BottomSearchField(placeholder: "搜索相册名、用户名、ID", text: $query)
                    .accessibilityIdentifier("albums-search")
                Button(selecting ? "完成" : "多选") {
                    selecting.toggle()
                    if !selecting { selected = [] }
                }
                .buttonStyle(ChipButtonStyle())
                .accessibilityIdentifier("albums-select")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    var body: some View {
        NavigationStack {
            Group {
                if access == false {
                    VStack(spacing: 12) {
                        Text("需要「完整照片访问」权限才能读到相册")
                            .multilineTextAlignment(.center)
                        Button("去系统设置里打开") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(ChipButtonStyle())
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if filter == .duplicates {
                            let found = groups
                            if allGroups == nil {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("正在找…").foregroundStyle(.secondary)
                                }
                            } else if found.isEmpty {
                                Text("没有发现可能重复的相册").foregroundStyle(.secondary)
                            }
                            ForEach(found, id: \.key) { g in
                                Section("名字里都有「\(g.key)」") {
                                    ForEach(g.albums) { row($0) }
                                }
                            }
                        } else {
                            let list = shown
                            Section {
                                if list.isEmpty {
                                    Text(infos.isEmpty ? "还没有自己建的相册" : "没有找到").foregroundStyle(.secondary)
                                }
                                ForEach(list) { row($0) }
                            } header: {
                                Text("\(list.count) 个相册")
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom) { bottomBar }
                }
            }
            .navigationTitle("相册")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { Task { await reload() } }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await reload() } }
            }
            .onChange(of: filter) { value in
                if value == .duplicates { Task { await findGroups() } }
            }
            .confirmationDialog("合并到哪一个？", isPresented: $askMerge, titleVisibility: .visible) {
                ForEach(picked) { info in
                    Button("合并到「\(String(info.title.prefix(20)))」") {
                        working = true
                        let sources = picked.map(\.album)
                        Task {
                            do {
                                try await Albums.merge(sources, into: info.album)
                                selecting = false
                                selected = []
                            } catch {
                                failure = error.localizedDescription
                            }
                            working = false
                            await reload()
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("其它选中的相册里的内容会放进它，然后删掉那些相册。照片不会丢。")
            }
            .alert("没有完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好") {}
            } message: {
                Text(failure ?? "")
            }
        }
    }
}

/// 一个相册的内容：看照片、改名、合并到别的相册、把照片移出 / 移走、删除相册。操作按钮在底部
struct AlbumDetailView: View {
    let album: PHAssetCollection
    /// 作为弹层打开时（下载页的「查看相册」）右上角放一个「完成」
    var showsDone = false

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var assets: [PHAsset] = []
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var viewing: PHAsset?
    @State private var renaming = false
    @State private var newName = ""
    /// 选相册是为了什么：合并整个相册，还是移动选中的照片
    @State private var pickingFor: PickPurpose?
    @State private var mergeTarget: Albums.Info?
    @State private var askDelete = false
    @State private var working = false
    @State private var failure: String?

    private enum PickPurpose: String, Identifiable {
        case merge, move
        var id: String { rawValue }
    }

    private func reload() {
        guard let fresh = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.localIdentifier],
                                                                  options: nil).firstObject else {
            dismiss()  // 相册已经不在了（被合并或删除）
            return
        }
        title = fresh.localizedTitle ?? ""
        assets = Albums.assets(in: fresh).reversed()  // 新的在前
        selected = selected.filter { id in assets.contains { $0.localIdentifier == id } }
    }

    private var picked: [PHAsset] { assets.filter { selected.contains($0.localIdentifier) } }

    /// 做一件会改相册的事：期间禁用按钮，失败了说明原因，完了重新读一遍
    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        Task {
            do { try await work() } catch { failure = error.localizedDescription }
            working = false
            reload()
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if selecting {
                HStack(spacing: 10) {
                    Button("移出相册") {
                        let items = picked
                        run {
                            try await Albums.remove(items, from: album)
                            selecting = false
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("album-remove")
                    Button("移到…") { pickingFor = .move }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("album-move")
                }
                .disabled(selected.isEmpty || working)
                Button("完成") {
                    selecting = false
                    selected = []
                }
                .buttonStyle(ChipButtonStyle())
            } else {
                HStack(spacing: 10) {
                    Button("改名") {
                        newName = title
                        renaming = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("album-detail-rename")
                    Button("合并到…") { pickingFor = .merge }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("album-detail-merge")
                }
                HStack(spacing: 10) {
                    Button("选择照片") { selecting = true }
                        .buttonStyle(ChipButtonStyle())
                        .disabled(assets.isEmpty)
                        .accessibilityIdentifier("album-detail-select")
                    Spacer()
                    Button("删除相册", role: .destructive) { askDelete = true }
                        .font(.subheadline.weight(.medium))
                        .accessibilityIdentifier("album-detail-delete")
                }
            }
        }
        .disabled(working)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.weight(.semibold))
                Text("\(assets.count) 项" + (selecting ? " · 已选 \(selected.count)" : ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        let on = selected.contains(asset.localIdentifier)
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { AssetThumb(asset: asset, side: 360) }
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(alignment: .bottomTrailing) {
                                if selecting {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(.white, on ? Color.accentColor : Color.black.opacity(0.25))
                                        .padding(5)
                                } else if asset.mediaType == .video {
                                    Image(systemName: "play.fill")
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                        .padding(6)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selecting {
                                    if on { selected.remove(asset.localIdentifier) } else { selected.insert(asset.localIdentifier) }
                                } else {
                                    viewing = asset
                                }
                            }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear { reload() }
        .sheet(item: Binding(get: { viewing.map(ViewedAsset.init) }, set: { if $0 == nil { viewing = nil } })) { v in
            AssetViewer(asset: v.asset)
        }
        .sheet(isPresented: $renaming) { renameSheet }
        .sheet(item: $pickingFor) { purpose in
            AlbumPicker(title: purpose == .merge ? "合并到哪个相册" : "移到哪个相册",
                        excluding: album.localIdentifier) { target in
                pickingFor = nil
                if purpose == .merge {
                    // 等选相册的那一页收起来再问，不然确认框弹不出来
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        mergeTarget = target
                    }
                } else {
                    let items = picked
                    run {
                        try await Albums.add(items, to: target.album)
                        try await Albums.remove(items, from: album)
                        selecting = false
                    }
                }
            }
        }
        .confirmationDialog("合并到「\(mergeTarget?.title ?? "")」？",
                            isPresented: Binding(get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } }),
                            titleVisibility: .visible, presenting: mergeTarget) { target in
            Button("合并，并删除这个相册") {
                run { try await Albums.merge([album], into: target.album) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("这里的 \(assets.count) 项会放进那个相册，然后删掉「\(title)」。照片不会丢。")
        }
        .confirmationDialog("删除相册「\(title)」？", isPresented: $askDelete, titleVisibility: .visible) {
            Button("删除相册", role: .destructive) {
                run { try await Albums.delete([album]) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删相册，里面的 \(assets.count) 项还在图库里。")
        }
        .alert("没有完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var renameSheet: some View {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 14) {
            Text("给相册改名").font(.headline)
            TextField("相册名", text: $newName, axis: .vertical)
                .padding(12)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("album-detail-name")
            Spacer(minLength: 0)
            Button("保存") {
                renaming = false
                run { try await Albums.rename(album, to: name) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(name.isEmpty || name == title)
        }
        .padding(20)
        .presentationDetents([.medium])
    }
}

private struct ViewedAsset: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

/// 放大看一张照片，或播放一个视频
private struct AssetViewer: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        // 内容在「关闭」上面剩下的地方居中（以前整个贴着底边放，照片会偏下）
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            Button("关闭") { dismiss() }
                .buttonStyle(ChipButtonStyle())
                .padding(.vertical, 10)
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            if asset.mediaType == .video {
                if let item = await Albums.playerItem(asset) {
                    let p = AVPlayer(playerItem: item)
                    player = p
                    p.play()
                }
            } else {
                image = await Albums.thumbnail(asset, side: 2400)
            }
        }
        .onDisappear { player?.pause() }
    }
}

/// 选一个相册（合并、移动时用）。搜索框和列表与「相册」页是同一套
struct AlbumPicker: View {
    let title: String
    /// 不列出这个相册（就是当前所在的那个）
    let excluding: String
    let onPick: (Albums.Info) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var infos: [Albums.Info] = []
    @State private var query = ""

    private var shown: [Albums.Info] {
        let list = infos.filter { $0.id != excluding }
        let parts = Albums.queryParts(query)
        if parts.isEmpty { return list }
        return list.filter { info in parts.allSatisfy { info.key.contains($0) } }
    }

    var body: some View {
        NavigationStack {
            List {
                if shown.isEmpty {
                    Text("没有找到").foregroundStyle(.secondary)
                }
                ForEach(shown) { info in
                    Button {
                        onPick(info)
                    } label: {
                        AlbumRow(title: info.title, count: info.count, cover: nil, album: info.album) { EmptyView() }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                BottomSearchField(placeholder: "搜索相册", text: $query)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task { infos = await Albums.infos() }
        }
    }
}
