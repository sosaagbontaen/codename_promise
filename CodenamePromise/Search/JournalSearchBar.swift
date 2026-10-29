import SwiftUI

/// The journal's header, with search folded into it. Closed, it's the wordmark, a
/// magnifying glass, and whatever sits at the end (the view switcher). Opening grows the
/// glass leftward into a search field over the wordmark, with a filter menu and Cancel at
/// the end. Filters that are on show underneath as chips, each with its own way to clear it.
struct JournalSearchBar<Accessory: View>: View {
    @Binding var isOpen: Bool
    @Binding var query: String
    @Binding var filter: SearchFilter
    /// What follows the glass while search is closed.
    @ViewBuilder let accessory: () -> Accessory

    @FocusState private var focused: Bool
    @State private var pickingRange = false
    /// The field's words, the filter menu and Cancel: shown once the capsule has mostly
    /// grown, hidden at once on closing, so nothing is drawn over the wordmark on the way.
    @State private var contentShown = false
    /// Measured, so the capsule knows where the glass sits closed and where it stops open.
    @State private var accessoryWidth: CGFloat = 0
    @State private var controlsWidth: CGFloat = 0

    private static var motion: Animation { .spring(response: 0.42, dampingFraction: 0.86) }
    private static var rowHeight: CGFloat { 40 }
    private static var glass: CGFloat { 36 }
    private static var gap: CGFloat { 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                // The capsule's two edges, as plain numbers so every frame between closed
                // and open is drawn: it starts as the glass and its left edge sweeps over
                // the wordmark while its right edge settles beside the filter menu.
                let width = geometry.size.width
                let closedRight = width - accessoryWidth - (accessoryWidth > 0 ? Self.gap : 0)
                let left = isOpen ? 0 : closedRight - Self.glass
                let right = isOpen ? width - controlsWidth - Self.gap : closedRight
                ZStack(alignment: .topLeading) {
                    Wordmark(size: 26)
                        .frame(height: Self.rowHeight)
                        .opacity(isOpen ? 0 : 1)
                        .animation(.easeOut(duration: 0.14), value: isOpen)
                        .accessibilityHidden(isOpen)

                    accessory()
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { accessoryWidth = $0 }
                        .frame(maxWidth: .infinity, maxHeight: Self.rowHeight, alignment: .trailing)
                        .opacity(isOpen ? 0 : 1)
                        .animation(.easeOut(duration: 0.14), value: isOpen)
                        .allowsHitTesting(!isOpen)
                        .accessibilityHidden(isOpen)

                    HStack(spacing: Self.gap) {
                        filterMenu
                        Button("Cancel", action: close)
                            .font(Type.label(15, .medium))
                            .foregroundStyle(Brand.violet)
                    }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { controlsWidth = $0 }
                    .frame(maxWidth: .infinity, maxHeight: Self.rowHeight, alignment: .trailing)
                    .opacity(contentShown ? 1 : 0)
                    .allowsHitTesting(isOpen)
                    .accessibilityHidden(!isOpen)

                    field
                        .frame(width: max(right - left, Self.glass), height: Self.rowHeight)
                        .offset(x: left)
                }
            }
            .frame(height: Self.rowHeight)
            if isOpen && filter.isActive { chips }
        }
        .padding(.top, 8)
        .sheet(isPresented: $pickingRange) {
            RangePicker(filter: $filter)
                .presentationDetents([.medium])
        }
    }

    /// The glass, which is the field: closed it's just the icon; open, the capsule has grown
    /// out of it to the left and the icon has ridden along to the field's leading edge.
    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: isOpen ? .regular : .semibold))
                .foregroundStyle(isOpen ? Brand.muted : Brand.ink)
                .frame(width: 20)
            TextField("Words, or what's in a photo", text: $query)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(Type.body(16))
                .opacity(contentShown ? 1 : 0)
                .disabled(!isOpen)
            if isOpen && !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .foregroundStyle(Brand.muted)
                .accessibilityLabel("Clear search")
            }
        }
        // Closed, the glass sits centred in its 36 points.
        .padding(.leading, isOpen ? 12 : 8)
        .padding(.trailing, isOpen ? 12 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Brand.surface.opacity(isOpen ? 1 : 0), in: Capsule())
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture { if !isOpen { open() } }
        .accessibilityElement(children: isOpen ? .contain : .ignore)
        .accessibilityAddTraits(isOpen ? [] : .isButton)
        .accessibilityLabel(isOpen ? "" : "Search")
    }

    private func open() {
        withAnimation(Self.motion) { isOpen = true }
        Task { @MainActor in
            // The keyboard rises with the field rather than before it.
            try? await Task.sleep(for: .milliseconds(120))
            focused = true
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeOut(duration: 0.16)) { contentShown = true }
        }
    }

    private func close() {
        focused = false
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { contentShown = false }
        withAnimation(Self.motion) {
            isOpen = false
            query = ""
            filter = SearchFilter()
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Dates", selection: Binding(
                get: { filter.dates },
                set: { dates in
                    if dates == .custom { pickingRange = true } else { filter.dates = dates }
                }
            )) {
                ForEach(SearchFilter.Dates.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Show", selection: $filter.show) {
                ForEach(SearchFilter.Show.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Order", selection: $filter.newestFirst) {
                Text("Newest first").tag(true)
                Text("Oldest first").tag(false)
            }
            .pickerStyle(.menu)
            if filter.isActive {
                Divider()
                Button("Clear filters", systemImage: "xmark") { filter = SearchFilter() }
            }
        } label: {
            Image(systemName: filter.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(filter.isActive ? Brand.violet : Brand.ink)
                .frame(width: 34, height: 40)
        }
        .accessibilityLabel("Filter results")
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if filter.dates != .anyTime {
                    chip(filter.datesLabel, symbol: "calendar") { filter.dates = .anyTime }
                }
                if filter.show != .all {
                    chip(filter.show.label, symbol: filter.show.symbol) { filter.show = .all }
                }
                if !filter.newestFirst {
                    chip("Oldest first", symbol: "arrow.up") { filter.newestFirst = true }
                }
            }
        }
    }

    private func chip(_ label: String, symbol: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(label)
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .font(Type.caption(12.5, .semibold))
            .foregroundStyle(Brand.violet)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Brand.monthBand, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove filter: \(label)")
    }
}

/// Two dates for a custom range, applied together so the results don't jump while picking.
private struct RangePicker: View {
    @Binding var filter: SearchFilter
    @Environment(\.dismiss) private var dismiss
    @State private var from = Date()
    @State private var to = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
                DatePicker("To", selection: $to, in: from..., displayedComponents: .date)
            }
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        filter.from = from
                        filter.to = to
                        filter.dates = .custom
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if filter.dates == .custom {
                from = filter.from
                to = filter.to
            } else {
                from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
                to = Date()
            }
        }
    }
}
