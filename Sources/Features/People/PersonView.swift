import SwiftUI
import GRDB

/// Dedicated view for a person: photo, bio, and everything you have with them.
struct PersonView: View {
    let person: CastMember

    @StateObject private var vm = PersonViewModel()
    @State private var selection: MediaItem?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 36), count: 6)

    var body: some View {
        ZStack {
            Theme.background

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 44) {
                    // Header: photo + name + bio.
                    HStack(alignment: .center, spacing: 44) {
                        CachedAsyncImage(url: largeProfileURL)
                            .frame(width: 260, height: 260)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 2))
                            .shadow(color: .black.opacity(0.5), radius: 30, y: 14)

                        VStack(alignment: .leading, spacing: 14) {
                            Text(person.name)
                                .font(.system(size: 54, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                            if let character = person.character {
                                Text(character)
                                    .font(.title3)
                                    .foregroundStyle(Theme.accentSoft)
                            }
                            // Facts: profession · birth (age) · place.
                            let facts = personFacts
                            if !facts.isEmpty {
                                Text(facts.joined(separator: "  ·  "))
                                    .font(.callout)
                                    .foregroundStyle(Theme.accentSoft)
                            }
                            if let bio = vm.biography {
                                Text(bio)
                                    .font(.callout)
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(5)
                                    .frame(maxWidth: 1000, alignment: .leading)
                            }
                            if !vm.items.isEmpty {
                                Text("\(vm.items.count) \(tr(L.titlesCount))")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(.top, 6)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 90)
                    .padding(.top, 80)

                    // Filmography available in the library.
                    if vm.loading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.top, 60)
                    } else if vm.items.isEmpty {
                        HStack {
                            Spacer()
                            Text(tr(L.personNothing))
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.4))
                            Spacer()
                        }
                        .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: columns, spacing: 48) {
                            ForEach(vm.items) { item in
                                GridPosterCard(item: item) { selection = $0 }
                            }
                        }
                        .padding(.horizontal, 90)
                        .padding(.bottom, 80)
                    }
                }
            }
            .scrollClipDisabled()
        }
        .ignoresSafeArea()
        .task { await vm.load(person: person) }
        .fullScreenCover(item: $selection) { item in
            DetailView(item: item)
        }
    }

    /// Available biographical facts, in presentation order.
    private var personFacts: [String] {
        var facts: [String] = []
        if let dept = vm.details.knownForDepartment, !dept.isEmpty {
            facts.append(localizedDepartment(dept))
        }
        if let birthday = vm.details.birthday, !birthday.isEmpty {
            var s = "\(tr(L.born)) \(vm.formattedDate(birthday))"
            if let age = vm.age { s += " · \(age) \(tr(L.yearsOld))" }
            facts.append(s)
        }
        if let death = vm.details.deathday, !death.isEmpty {
            facts.append("\(tr(L.died)) \(vm.formattedDate(death))")
        }
        if let place = vm.details.placeOfBirth, !place.isEmpty {
            facts.append(place)
        }
        return facts
    }

    private func localizedDepartment(_ dept: String) -> String {
        guard L10nStore.shared.effective == "es" else { return dept }
        switch dept {
        case "Acting": return "Actuación"
        case "Directing": return "Dirección"
        case "Writing": return "Guion"
        case "Production": return "Producción"
        case "Sound": return "Sonido"
        case "Camera": return "Fotografía"
        default: return dept
        }
    }

    private var largeProfileURL: URL? {
        guard let url = person.profileURL else { return nil }
        return URL(string: url.absoluteString.replacingOccurrences(of: "/w185", with: "/w500"))
    }
}

@MainActor
final class PersonViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var details = TMDBClient.PersonDetails()
    @Published var loading = true

    var biography: String? { details.biography }

    func load(person: CastMember) async {
        defer { loading = false }
        guard let key = SettingsStore.shared.tmdbKey else { return }

        async let detailsTask = TMDBClient.personDetails(personID: person.id, key: key, lang: L10nStore.shared.effective)
        let filmography = await TMDBBrowse.personFilmography(personID: person.id, key: key)
        details = await detailsTask

        guard !filmography.isEmpty else { return }

        // Parental first shield by age certification (cert-aware; handles virtual items).
        let safe = await ParentalStore.shared.filterDiscover(filmography)
        guard !safe.isEmpty else { items = []; return }

        // Local copies by tmdbID to map to the library when they exist.
        let ids = safe.map(\.tmdbID)
        let locals = (try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem.filter(ids.contains(Column("tmdbID"))).fetchAll(db)
        }) ?? []
        let localByKey = HomeViewModel.merged(locals).reduce(into: [String: MediaItem]()) { $0[$1.mergeKey] = $1 }
        let catalogBrowse = SettingsStore.shared.fullCatalogEnabled

        // The full TMDB filmography: local copy if it exists; otherwise a virtual title
        // (only if the TMDB catalog is available, so it is playable).
        items = safe.compactMap { film in
            if let local = localByKey[film.mergeKey] { return local }
            return catalogBrowse ? MediaItem.virtualStub(from: film) : nil
        }
    }

    /// Age from birth (until today or death).
    var age: Int? {
        guard let birthday = details.birthday, let birth = Self.date(birthday) else { return nil }
        let end = details.deathday.flatMap(Self.date) ?? Date()
        return Calendar(identifier: .gregorian).dateComponents([.year], from: birth, to: end).year.flatMap { $0 >= 0 ? $0 : nil }
    }

    private static func date(_ iso: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)
    }

    func formattedDate(_ iso: String) -> String {
        guard let d = Self.date(iso) else { return iso }
        let out = DateFormatter()
        out.locale = Locale(identifier: L10nStore.shared.effective == "es" ? "es" : "en")
        out.dateStyle = .long
        return out.string(from: d)
    }
}
