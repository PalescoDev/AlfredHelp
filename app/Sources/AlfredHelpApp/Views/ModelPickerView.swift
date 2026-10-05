import SwiftUI
import AlfredHelpCore

/// The one decision the app asks the user to make.
///
/// Only models that are actually on this Mac are selectable. Anything else
/// would offer a choice that silently turns into a multi-gigabyte download –
/// so downloads live in their own collapsed section and are never mixed into
/// the selection.
///
/// Every number is measured, not claimed: `Benchmarks/benchmark.py` asks each
/// model the same eight technical questions and counts how many of the required
/// key points the answer really contains, while recording throughput.
struct ModelPickerView: View {
    @Bindable var model: AppModel
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                Text("Sprachmodell")
                    .font(.system(size: 13, weight: .semibold))
                Text("AlfredHelp startet Ollama und lädt das Modell. Mithören startest du selbst oder nach aktiviertem Autostart.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let status = model.pullStatus {
                ProgressView(status, value: model.pullFraction)
                    .progressViewStyle(.linear)
                    .font(.caption)
            } else if let status = model.modelStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }

            if installed.isEmpty {
                emptyState
            } else {
                VStack(spacing: 6) {
                    ForEach(installed) { entry in
                        ModelRow(
                            entry: entry,
                            isSelected: entry.name == model.settings.qualityModel,
                            isBusy: isBusy,
                            select: { model.selectModel(entry.name) }
                        )
                    }
                }
            }

            if model.helperIsMissing {
                helperOffer
            } else if !installed.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.system(size: 10))
                    Text(helperExplanation).font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
            }

            if !downloadable.isEmpty {
                DisclosureGroup {
                    VStack(spacing: 6) {
                        ForEach(downloadable) { profile in
                            DownloadRow(
                                profile: profile,
                                isBusy: isBusy,
                                download: { model.selectModel(profile.name) }
                            )
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label(
                        "Weitere Modelle herunterladen (\(downloadable.count))",
                        systemImage: "arrow.down.circle"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Zustände

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
            VStack(alignment: .leading, spacing: 2) {
                Text("Noch kein Modell installiert")
                    .font(.system(size: 12, weight: .medium))
                Text("Unten ein Modell auswählen und herunterladen. Empfohlen: "
                     + "\(ModelCatalog.profiles.first?.name ?? "gemma3:12b").")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .cardBackground()
    }

    private var helperOffer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hare").font(.system(size: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text("Schneller mit einem kleinen Helfer")
                    .font(.system(size: 11, weight: .medium))
                Text("Übersetzung und Frageerkennung laufen gerade auf \(model.settings.qualityModel) mit. "
                     + "Gemessen mit \(ModelCatalog.preferredHelper.name): Frageerkennung 375 statt 881 ms "
                     + "und ein Erkennungsfehler weniger. "
                     + String(format: "%.1f GB", ModelCatalog.preferredHelper.approximateGigabytes) + ".")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("Laden") { model.installHelperModel() }
                .controlSize(.small)
                .disabled(isBusy)
        }
        .padding(9)
        .cardBackground()
    }

    // MARK: - Daten

    private var isBusy: Bool { model.pullStatus != nil || model.modelStatus != nil }

    /// Genau das, was auf diesem Mac liegt – nichts anderes ist wählbar.
    private var installed: [InstalledModel] {
        model.installedModels
            .filter { !ModelCatalog.isKnownUnsuitable($0.name) }
            .map { InstalledModel(name: $0.name, parameterSize: $0.parameterSize,
                                  sizeBytes: $0.sizeBytes, profile: ModelCatalog.profile(for: $0.name)) }
            .sorted { lhs, rhs in
                // Vermessene zuerst, darin die mit der besseren Abdeckung.
                switch (lhs.profile, rhs.profile) {
                case let (left?, right?): return left.coveragePercent > right.coveragePercent
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.name < rhs.name
                }
            }
    }

    /// Vermessene Modelle, die hier nicht liegen – bewusst getrennt.
    private var downloadable: [ModelCatalog.Profile] {
        let present = Set(model.installedModels.map(\.name))
        return ModelCatalog.profiles.filter { !present.contains($0.name) }
    }

    private var helperExplanation: String {
        let helper = model.settings.fastModel
        guard !helper.isEmpty, helper != model.settings.qualityModel else {
            return "Übersetzung und Frageerkennung laufen auf demselben Modell."
        }
        return "Übersetzung und Frageerkennung übernimmt \(helper) im Hintergrund."
    }
}

/// Ein Modell, das tatsächlich auf diesem Mac liegt.
struct InstalledModel: Identifiable {
    let name: String
    let parameterSize: String
    let sizeBytes: Int64
    /// Messwerte, sofern das Modell im Benchmark war.
    let profile: ModelCatalog.Profile?

    var id: String { name }
    var gigabytes: Double { Double(sizeBytes) / 1_073_741_824 }
}

private struct ModelRow: View {
    let entry: InstalledModel
    let isSelected: Bool
    let isBusy: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name).font(.callout.weight(.medium))
                        Text(String(format: "%.1f GB", entry.gigabytes))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.profile?.summary ?? "Selbst installiert – nicht vermessen, funktioniert aber.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if let profile = entry.profile {
                    VStack(alignment: .trailing, spacing: 2) {
                        RatingLine(label: "Qualität", stars: profile.qualityStars,
                                   detail: "\(profile.coveragePercent) %")
                        RatingLine(label: "Tempo", stars: profile.speedStars,
                                   detail: "\(profile.tokensPerSecond) Tok/s")
                    }
                } else {
                    Text(entry.parameterSize.isEmpty ? "—" : entry.parameterSize)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.cardCorner)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCorner)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.18),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.5 : 1)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "Aktuell ausgewählt" : "Als Antwortmodell auswählen")
    }
}

/// Ein Modell, das erst geladen werden müsste – klar als Download gekennzeichnet.
private struct DownloadRow: View {
    let profile: ModelCatalog.Profile
    let isBusy: Bool
    let download: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.callout)
                Text(profile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                RatingLine(label: "Qualität", stars: profile.qualityStars,
                           detail: "\(profile.coveragePercent) %")
                RatingLine(label: "Tempo", stars: profile.speedStars,
                           detail: "\(profile.tokensPerSecond) Tok/s")
            }
            Button(action: download) {
                Label(
                    String(format: "Laden · %.1f GB", profile.approximateGigabytes),
                    systemImage: "arrow.down.circle"
                )
            }
                .controlSize(.small)
                .disabled(isBusy)
                .accessibilityLabel("\(profile.name) herunterladen")
                .accessibilityValue(String(format: "%.1f Gigabyte", profile.approximateGigabytes))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }
}

/// One "Qualität ●●●●○ 94 %" line.
private struct RatingLine: View {
    let label: String
    let stars: Int
    let detail: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .fill(index < stars ? tint : Color.secondary.opacity(0.22))
                        .frame(width: 5, height: 5)
                }
            }
            Text(detail)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(stars) von 5")
        .accessibilityValue(detail)
    }

    private var tint: Color {
        switch stars {
        case 5: return .green
        case 4: return .teal
        case 3: return .yellow
        default: return .orange
        }
    }
}
