import SwiftUI

/// The journal's header while searching: the field, a filter menu, and Cancel. Filters that
/// are on show underneath as chips, each with its own way to clear it.
struct JournalSearchBar: View {
    @Binding var query: String
    @Binding var filter: SearchFilter
    let onCancel: () -> Void

    @FocusState private var focused: Bool
    @State private var pickingRange = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Brand.muted)
                    TextField("Words, or what's in a photo", text: $query)
                        .focused($focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .foregroundStyle(Brand.muted)
                        .accessibilityLabel("Clear search")
                    }
                }
                .font(Type.body(16))
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Brand.surface, in: Capsule())

                filterMenu

                Button("Cancel", action: onCancel)
                    .font(Type.label(15, .medium))
                    .foregroundStyle(Brand.violet)
            }
            if filter.isActive { chips }
        }
        .padding(.top, 8)
        .onAppear { focused = true }
        .sheet(isPresented: $pickingRange) {
            RangePicker(filter: $filter)
                .presentationDetents([.medium])
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
