import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case auto
    case english = "en"
    case spanish = "es"
    var id: String { rawValue }
}

@MainActor
final class L10nStore: ObservableObject {
    static let shared = L10nStore()

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
            // Re-downloads metadata (titles, synopses, posters, logos) in the new language.
            Task { await TMDBEnricher.shared.enrichAll() }
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"
        language = AppLanguage(rawValue: saved) ?? .auto
    }

    /// Effective language: manual setting, or the system's with English fallback.
    var effective: String {
        L10n.effectiveLanguage()
    }

    #if LUMORA_ICLOUD
    /// Re-reads the app language after iCloud KVS delivered a remote change.
    func reloadFromDefaults() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"
        let lang = AppLanguage(rawValue: saved) ?? .auto
        if lang != language { language = lang }
    }
    #endif
}

/// Thread-safe language resolution, usable from any isolation context
/// (views, async clients, LocalizedError descriptions).
enum L10n {
    static func effectiveLanguage() -> String {
        switch UserDefaults.standard.string(forKey: "appLanguage") ?? "auto" {
        case "en": "en"
        case "es": "es"
        default: Locale.preferredLanguages.first?.hasPrefix("es") == true ? "es" : "en"
        }
    }
}

struct LString: Equatable, Sendable {
    let en: String
    let es: String
}

func tr(_ s: LString) -> String {
    L10n.effectiveLanguage() == "es" ? s.es : s.en
}

/// Translated string with `String(format:)` interpolation (%@, %d…).
func trf(_ s: LString, _ args: CVarArg...) -> String {
    String(format: tr(s), arguments: args)
}

// MARK: - Strings

enum L {
    // General
    static let back = LString(en: "Back", es: "Volver")
    static let cancel = LString(en: "Cancel", es: "Cancelar")
    static let retry = LString(en: "Retry", es: "Reintentar")
    static let close = LString(en: "Close", es: "Cerrar")
    static let save = LString(en: "Save", es: "Guardar")
    static let delete = LString(en: "Delete", es: "Borrar")

    // Onboarding
    static let appTagline = LString(en: "Your personal cinema.", es: "Tu cine personal.")
    static let appSubtitle = LString(
        en: "Connect your media server and enjoy your collection\nwith a next-level experience.",
        es: "Conecta tu servidor de medios y disfruta de tu colección\ncon una experiencia de otro nivel."
    )
    static let start = LString(en: "Get Started", es: "Comenzar")
    static let connectTitle = LString(en: "Connect your media server", es: "Conecta tu servidor de medios")
    static let connectSubtitle = LString(en: "Choose how you want to connect", es: "Elige cómo quieres conectarte")
    static let serverOptionalHint = LString(
        en: "Optional: connect a media server to stream your own library. You can also do it later in Settings — your catalog already works.",
        es: "Opcional: conecta un servidor de medios para reproducir tu propia biblioteca. También puedes hacerlo luego en Ajustes — tu catálogo ya funciona."
    )
    static let skipServerStep = LString(en: "Skip — connect later", es: "Omitir — conectar después")
    static let doneNoServer = LString(
        en: "No media server yet — add one anytime in Settings",
        es: "Aún sin servidor — añade uno cuando quieras en Ajustes"
    )
    static let linkCardTitle = LString(en: "Automatic link", es: "Vinculación automática")
    static let linkCardDesc = LString(
        en: "We give you a short code, you type it on your phone and we find your servers automatically.",
        es: "Te damos un código corto, lo escribes en tu teléfono y encontramos tus servidores automáticamente."
    )
    static let recommended = LString(en: "Recommended", es: "Recomendado")
    static let manualCardTitle = LString(en: "Manual setup", es: "Configuración manual")
    static let manualCardDesc = LString(
        en: "Enter your server's IP address, port and token directly.",
        es: "Escribe la dirección IP, el puerto y el token de tu servidor directamente."
    )
    static let linkTitle = LString(en: "Link your account", es: "Vincula tu cuenta")
    static let linkSubtitle = LString(en: "From your phone or computer", es: "Desde tu teléfono u ordenador")
    static let linkStep1 = LString(en: "Go to", es: "Entra en")
    static let linkStep2 = LString(en: "Enter this code:", es: "Escribe este código:")
    static let waitingLink = LString(en: "Waiting for link…", es: "Esperando vinculación…")
    static let newCode = LString(en: "Generate new code", es: "Generar nuevo código")
    static let scanWithIphone = LString(en: "Or scan with your iPhone", es: "O escanea con tu iPhone")
    static let codeAutofills = LString(en: "The code fills in automatically", es: "El código se rellena solo")
    static let pickServerTitle = LString(en: "Choose your server", es: "Elige tu servidor")
    static let pickServerSubtitle = LString(en: "We found these servers in your account", es: "Encontramos estos servidores en tu cuenta")
    static let searchingServers = LString(en: "Finding servers and testing connections…", es: "Buscando servidores y probando conexiones…")
    static let localNetwork = LString(en: "Local network", es: "Red local")
    static let remote = LString(en: "Remote", es: "Remoto")
    static let directConnection = LString(en: "Direct connection", es: "Conexión directa")
    static let manualTitle = LString(en: "Manual setup", es: "Configuración manual")
    static let manualTip = LString(
        en: "Tip: when you select a field, you can type from your iPhone",
        es: "Consejo: cuando selecciones un campo, puedes escribir desde tu iPhone"
    )
    static let hostPlaceholder = LString(en: "IP address (e.g. 192.168.1.50)", es: "Dirección IP (ej. 192.168.1.50)")
    static let portPlaceholder = LString(en: "Port (default 32400)", es: "Puerto (por defecto 32400)")
    static let tokenPlaceholder = LString(en: "Access token (optional on local network)", es: "Token de acceso (opcional en red local)")
    static let connect = LString(en: "Connect", es: "Conectar")
    static let connecting = LString(en: "Connecting…", es: "Conectando…")
    static let tmdbTitle = LString(en: "Premium metadata", es: "Metadata premium")
    static let tmdbSubtitle = LString(
        en: "Required — The Movie Database organizes your whole catalog: posters, logos, recommendations and more",
        es: "Obligatorio — The Movie Database organiza todo tu catálogo: pósters, logos, recomendaciones y más"
    )
    static let tmdbStep1 = LString(en: "Create a free account at themoviedb.org", es: "Crea una cuenta gratis en themoviedb.org")
    static let tmdbStep2 = LString(en: "Go to Settings → API and copy your key", es: "Ve a Ajustes → API y copia tu clave")
    static let tmdbStep3 = LString(en: "Paste it here — it's faster with your iPhone", es: "Pégala aquí — con tu iPhone es más rápido")
    static let tmdbPlaceholder = LString(en: "TMDB API key", es: "Clave de API de TMDB")
    static let tmdbApiKey = LString(en: "TMDB API key", es: "Clave de API de TMDB")
    static let tmdbUpdateKey = LString(en: "Update API key", es: "Actualizar clave de API")
    static let tmdbInvalidKey = LString(en: "Invalid API key.", es: "Clave de API inválida.")
    static let validate = LString(en: "Validate and continue", es: "Validar y continuar")
    static let validating = LString(en: "Validating…", es: "Validando…")
    static let skipForNow = LString(en: "Set up later", es: "Configurar más tarde")
    static let doneTitle = LString(en: "All set", es: "Todo listo")
    static let connectedTo = LString(en: "Connected to", es: "Conectado a")
    static let tmdbActive = LString(en: "Premium metadata enabled", es: "Metadata premium activada")
    static let tmdbPending = LString(en: "Premium metadata pending (enable it in Settings)", es: "Metadata premium pendiente (actívala en Ajustes)")
    static let exploreLibrary = LString(en: "Explore my library", es: "Explorar mi biblioteca")

    // Errores
    static let errLinkExpired = LString(en: "The code expired. Generate a new one.", es: "El código expiró. Genera uno nuevo.")
    static let errPlexTv = LString(
        en: "Couldn't reach plex.tv. Check your Apple TV's internet connection.",
        es: "No se pudo contactar con plex.tv. Revisa la conexión a internet del Apple TV."
    )
    static let errNoServers = LString(
        en: "Your account has no servers reachable from this network.",
        es: "Tu cuenta no tiene servidores accesibles desde esta red."
    )
    static let errResources = LString(en: "Couldn't fetch your servers from plex.tv.", es: "No se pudieron obtener tus servidores de plex.tv.")
    static let errHostRequired = LString(en: "Enter the server's IP address or hostname.", es: "Escribe la dirección IP o el nombre del servidor.")
    static let errManualConnect = LString(en: "Couldn't connect. Check IP, port and token.", es: "No se pudo conectar. Verifica IP, puerto y token.")
    static let errTmdbKey = LString(
        en: "Invalid key. Check it at themoviedb.org → Settings → API.",
        es: "La clave no es válida. Revísala en themoviedb.org → Ajustes → API."
    )

    // Tabs
    static let tabHome = LString(en: "Home", es: "Inicio")
    static let tabMovies = LString(en: "Movies", es: "Películas")
    static let tabShows = LString(en: "TV Shows", es: "Series")
    static let tabAnime = LString(en: "Anime", es: "Anime")
    static let tabDoramas = LString(en: "Doramas", es: "Doramas")
    static let tabDocumentaries = LString(en: "Documentaries", es: "Documentales")
    static let tabSearch = LString(en: "Search", es: "Buscar")
    static let tabSettings = LString(en: "Settings", es: "Ajustes")

    // Home / sync
    static let shelfContinue = LString(en: "Continue Watching", es: "Continuar viendo")
    /// Continue Watching card: time left, e.g. "12 min left" / "faltan 12 min".
    static let continueLeft = LString(en: "%@ left", es: "faltan %@")
    static let shelfRecent = LString(en: "Recently Added", es: "Recién agregado")
    static let shelfTopPicks = LString(en: "Top Rated For You", es: "Lo mejor valorado para ti")
    static let shelfGems = LString(en: "Hidden Gems", es: "Joyas sin descubrir")
    static let preparing = LString(en: "Preparing your personal cinema…", es: "Preparando tu cine personal…")
    static let syncingLibrary = LString(en: "Syncing", es: "Sincronizando")
    static let play = LString(en: "Play", es: "Reproducir")
    static let comingSoon = LString(en: "Coming soon", es: "Próximamente")
    static let emptyLibrary = LString(en: "Nothing here yet", es: "Aún no hay nada aquí")

    // Detail / Player
    static let playSoon = LString(en: "Play (coming soon)", es: "Reproducir (próximamente)")
    static let audio = LString(en: "Audio", es: "Audio")
    static let subtitles = LString(en: "Subtitles", es: "Subtítulos")
    static let subtitlesOff = LString(en: "Off", es: "Desactivados")
    static let downloadSubtitles = LString(en: "Download subtitles", es: "Descargar subtítulos")
    static let searchingSubtitles = LString(en: "Searching subtitles…", es: "Buscando subtítulos…")
    static let noSubtitlesFound = LString(en: "No subtitles found", es: "No se encontraron subtítulos")
    static let exactMatch = LString(en: "Exact match", es: "Coincidencia exacta")
    static let openSubtitlesSection = LString(en: "Subtitles (OpenSubtitles)", es: "Subtítulos (OpenSubtitles)")
    static let osApiKey = LString(en: "OpenSubtitles API key", es: "API key de OpenSubtitles")
    static let osUsername = LString(en: "Username", es: "Usuario")
    static let osPassword = LString(en: "Password", es: "Contraseña")
    static let playbackError = LString(en: "Couldn't start playback.", es: "No se pudo iniciar la reproducción.")
    static let info = LString(en: "Info", es: "Información")
    static let playerSettings = LString(en: "Settings", es: "Ajustes")
    static let subtitleSize = LString(en: "Size", es: "Tamaño")
    static let subtitleFont = LString(en: "Font", es: "Fuente")
    static let subtitleColor = LString(en: "Color", es: "Color")
    static let sizeSmall = LString(en: "Small", es: "Pequeño")
    static let sizeMedium = LString(en: "Medium", es: "Mediano")
    static let sizeLarge = LString(en: "Large", es: "Grande")
    static let sizeXLarge = LString(en: "Extra large", es: "Extra grande")
    static let fontDefault = LString(en: "Default", es: "Por defecto")
    static let fontRounded = LString(en: "Rounded", es: "Redondeada")
    static let fontSerif = LString(en: "Serif", es: "Clásica")
    static let fontMono = LString(en: "Mono", es: "Mono")
    static let colorWhite = LString(en: "White", es: "Blanco")
    static let colorYellow = LString(en: "Yellow", es: "Amarillo")
    static let colorCyan = LString(en: "Cyan", es: "Cian")
    static let resume = LString(en: "Resume", es: "Reanudar")
    static let trailer = LString(en: "Trailer", es: "Tráiler")
    static let castTitle = LString(en: "Cast", es: "Reparto")
    static let similarTitle = LString(en: "More Like This", es: "Más como esto")
    static let technicalTitle = LString(en: "Details", es: "Detalles")
    static let chooseVersion = LString(en: "Choose a version", es: "Elige la versión")
    static let serversTitle = LString(en: "Servers", es: "Servidores")
    static let addServer = LString(en: "Add server", es: "Añadir servidor")
    static let removeServer = LString(en: "Remove", es: "Quitar")
    static let relinkPlex = LString(en: "Re-link account", es: "Re-vincular cuenta")
    static let independenceDisclaimer = LString(
        en: "LumoraTV is an independent, open-source project created to explore the capabilities of Anthropic's model. It is not affiliated with, endorsed, sponsored or certified by any of the services it can connect to. All product names, logos and trademarks are property of their respective owners; LumoraTV acts only as a client that you configure and run yourself.",
        es: "LumoraTV es un proyecto independiente y de código abierto creado para explorar las capacidades del modelo de Anthropic. No está afiliado, respaldado, patrocinado ni certificado por ninguno de los servicios a los que puede conectarse. Todos los nombres de productos, logos y marcas pertenecen a sus respectivos dueños; LumoraTV actúa solo como un cliente que tú configuras y ejecutas."
    )
    static let searchingNewServers = LString(en: "Looking for servers in your account…", es: "Buscando servidores en tu cuenta…")
    static let noNewServers = LString(en: "No new servers found.", es: "No se encontraron servidores nuevos.")

    // Control parental
    static let parentalTitle = LString(en: "Parental Controls", es: "Control parental")
    static let parentalEnable = LString(en: "Enable", es: "Activar")
    static let parentalDisable = LString(en: "Disable", es: "Desactivar")
    static let parentalSetPin = LString(en: "Choose a 4-digit PIN", es: "Elige un PIN de 4 dígitos")
    static let parentalEnterPin = LString(en: "Enter PIN", es: "Introduce el PIN")
    static let parentalWrongPin = LString(en: "Wrong PIN", es: "PIN incorrecto")
    static let parentalUnlock = LString(en: "Unlock", es: "Desbloquear")
    static let parentalHint = LString(
        en: "Choose the maximum rating to show. It applies immediately. The PIN is optional and only protects this setting.",
        es: "Elige la clasificación máxima a mostrar. Se aplica de inmediato. El PIN es opcional y solo protege este ajuste."
    )
    static let parentalOptionalPin = LString(en: "Protect with PIN (optional)", es: "Proteger con PIN (opcional)")
    static let parentalChangePin = LString(en: "Change PIN", es: "Cambiar PIN")
    static let parentalRemovePin = LString(en: "Remove PIN", es: "Quitar PIN")
    static let parentalMaxRating = LString(en: "Maximum rating", es: "Clasificación máxima")
    static let ratingKids = LString(en: "Kids (G)", es: "Niños (G)")
    static let rating7 = LString(en: "7+ (PG)", es: "7+ (PG)")
    static let rating13 = LString(en: "13+ (PG-13)", es: "13+ (PG-13)")
    static let ratingAll = LString(en: "Everything (18+)", es: "Todo (18+)")
    static let parentalActive = LString(en: "Active — content is filtered for this user", es: "Activo — el contenido se filtra para este usuario")

    // Personas
    static let personInLibrary = LString(en: "In your library", es: "En tu biblioteca")
    static let titlesCount = LString(en: "titles", es: "títulos")
    static let servicesSection = LString(en: "Services", es: "Servicios")
    static let testConnection = LString(en: "Test connection", es: "Probar conexión")
    static let noPreview = LString(en: "No preview available", es: "Sin vista previa disponible")
    static let autoBestSource = LString(en: "Auto-play best source", es: "Reproducir la mejor fuente automáticamente")
    static let autoBestSourceHint = LString(
        en: "Skip the source picker and play the best available release. You can still change source in the player.",
        es: "Omite el selector y reproduce el mejor release disponible. Puedes cambiar de fuente en el reproductor."
    )
    static let categoriesTitle = LString(en: "Browse by category", es: "Explora por categoría")
    static let filterSortRecent = LString(en: "Recent", es: "Recientes")
    static let filterSortPopular = LString(en: "Popular", es: "Populares")
    static let filterSortRating = LString(en: "Top rated", es: "Mejor valorados")
    static let filterAll = LString(en: "Any rating", es: "Cualquier nota")
    static let filterAnyYear = LString(en: "Any year", es: "Cualquier año")
    static let filterAllGenres = LString(en: "All genres", es: "Todos los géneros")
    static let filterSort = LString(en: "Sort", es: "Orden")
    static let filterGenre = LString(en: "Genre", es: "Género")
    static let filterYear = LString(en: "Year", es: "Año")
    static let filterRatingShort = LString(en: "Rating", es: "Nota")
    static let filterSortOldest = LString(en: "Oldest", es: "Más antiguos")
    static let filterAnyShort = LString(en: "Any", es: "Cualquiera")
    static let filterAllShort = LString(en: "All", es: "Todos")
    static let filtersTitle = LString(en: "Filters", es: "Filtros")
    static let born = LString(en: "Born", es: "Nació el")
    static let died = LString(en: "Died", es: "Falleció el")
    static let yearsOld = LString(en: "years old", es: "años")
    static let personNothing = LString(en: "Nothing in your library with this person yet.", es: "Aún no tienes nada con esta persona en tu biblioteca.")
    static let becauseYouLike = LString(en: "Because you like", es: "Porque te gusta")
    static let newEpisodes = LString(en: "New Episodes", es: "Nuevos episodios")
    static let stopWatchingShow = LString(en: "Stop watching this show", es: "Dejar de ver esta serie")

    // Mi lista / seguimiento
    static let myList = LString(en: "My List", es: "Mi lista")
    static let inMyList = LString(en: "In My List", es: "En mi lista")
    static let resumePromptTitle = LString(en: "Resume playback?", es: "¿Continuar donde ibas?")
    static let resumeFrom = LString(en: "Resume from", es: "Continuar desde")
    static let playFromStart = LString(en: "From the beginning", es: "Desde el inicio")
    static let watchedOn = LString(en: "Watched on", es: "Visto el")
    static let viewInfo = LString(en: "View info", es: "Ver información")
    static let removeFromContinue = LString(en: "Remove from Continue Watching", es: "Quitar de Continuar viendo")
    static let addToMyList = LString(en: "Add to My List", es: "Agregar a Mi lista")
    static let removeFromMyList = LString(en: "Remove from My List", es: "Quitar de Mi lista")
    static let markWatched = LString(en: "Mark as watched", es: "Marcar como visto")
    static let markUnwatched = LString(en: "Mark as unwatched", es: "Marcar como no visto")
    static let skipIntro = LString(en: "Skip Intro", es: "Saltar intro")
    static let skipCredits = LString(en: "Skip Credits", es: "Saltar créditos")
    static let nextEpisode = LString(en: "Next Episode", es: "Siguiente episodio")
    static let playingIn = LString(en: "Playing in", es: "Reproduciendo en")
    static let youFinished = LString(en: "You finished", es: "Terminaste")
    static let missingNextTitle = LString(en: "Next episode is missing", es: "Falta el siguiente episodio")
    static let notInLibrary = LString(en: "is not in your library yet", es: "aún no está en tu biblioteca")
    static let didYouLike = LString(en: "Did you like it?", es: "¿Te gustó?")
    static let exitLabel = LString(en: "Exit", es: "Salir")
    static let forYou = LString(en: "For You", es: "Para ti")
    static let swipeHint = LString(en: "Swipe down for info, audio and subtitles", es: "Desliza hacia abajo para información, audio y subtítulos")

    // Settings
    static let language = LString(en: "Language", es: "Idioma")
    static let audioLanguage = LString(en: "Preferred audio", es: "Audio preferido")
    static let subtitleLanguage = LString(en: "Preferred subtitles", es: "Subtítulos preferidos")
    static let original = LString(en: "Original", es: "Original")
    static let langAuto = LString(en: "Automatic (Apple TV)", es: "Automático (Apple TV)")
    static let langEn = LString(en: "English", es: "English")
    static let langEs = LString(en: "Español", es: "Español")
    static let server = LString(en: "Server", es: "Servidor")
    static let lastSync = LString(en: "Last sync", es: "Última sincronización")
    static let never = LString(en: "Never", es: "Nunca")
    static let syncNow = LString(en: "Sync now", es: "Sincronizar ahora")
    static let resetAll = LString(en: "Reset configuration", es: "Restablecer configuración")
    static let tmdbConfigured = LString(en: "Configured", es: "Configurada")
    static let tmdbNotConfigured = LString(en: "Not configured", es: "Sin configurar")
    static let searchPlaceholder = LString(en: "Search your library", es: "Busca en tu biblioteca")
    static let noResults = LString(en: "No results for", es: "Sin resultados para")
    static let noResultsHint = LString(en: "Check the spelling or try another title", es: "Revisa la ortografía o intenta con otro título")
    static let searchHint = LString(en: "Find movies and shows across all your servers", es: "Encuentra películas y series en todos tus servidores")
    static let recentSearches = LString(en: "Recent searches", es: "Búsquedas recientes")
    static let clearRecents = LString(en: "Clear", es: "Borrar")
    static let playbackSection = LString(en: "Playback", es: "Reproducción")
    static let subtitleStyle = LString(en: "Subtitle style", es: "Estilo de subtítulos")
    static let systemSection = LString(en: "System", es: "Sistema")
    static let appVersion = LString(en: "Version", es: "Versión")
    static let licensesTitle = LString(en: "Licenses & attributions", es: "Licencias y atribuciones")
    static let licensesIntro = LString(
        en: "LumoraTV is built with open source software:",
        es: "LumoraTV está construido con software de código abierto:"
    )
    static let metadataSection = LString(en: "Metadata (TMDB)", es: "Metadata (TMDB)")
    static let storageSection = LString(en: "Storage", es: "Almacenamiento")
    static let imageCacheLabel = LString(en: "Image cache", es: "Caché de imágenes")
    static let databaseLabel = LString(en: "Local database", es: "Base de datos local")
    static let cacheLimitLabel = LString(en: "Cache limit", es: "Límite del caché")
    static let unlimited = LString(en: "Unlimited", es: "Sin límite")
    static let clearCache = LString(en: "Clear image cache", es: "Borrar caché de imágenes")
    static let inUse = LString(en: "in use", es: "en uso")
    static let syncFailedLabel = LString(en: "Last sync failed — check your servers", es: "Falló la última sincronización — revisa tus servidores")
    static let episodesTab = LString(en: "Episodes", es: "Episodios")
    static let episodesCount = LString(en: "episodes", es: "episodios")
    static let seasonsCount = LString(en: "seasons", es: "temporadas")
    static let speedTest = LString(en: "Speed test", es: "Prueba de velocidad")
    static let speedTesting = LString(en: "Testing…", es: "Probando…")
    static let sourceTab = LString(en: "Source", es: "Fuente")
    static let dlSpeed = LString(en: "Download", es: "Descarga")
    static let seedersPeers = LString(en: "Seeders / Peers", es: "Seeders / Peers")
    static let buffered = LString(en: "Buffered", es: "En búfer")
    static let otherSources = LString(en: "Other sources", es: "Otras fuentes")
    static let nowPlayingSource = LString(en: "Current source", es: "Fuente actual")
    static let torrentSource = LString(en: "Torrent", es: "Torrent")
    static let searchingSources = LString(en: "Finding sources…", es: "Buscando fuentes…")
    static let changeSource = LString(en: "Change source", es: "Cambiar fuente")
    static let chaptersLabel = LString(en: "Chapters", es: "Capítulos")
    static let chapterWord = LString(en: "Chapter", es: "Capítulo")
    static let connectionLost = LString(en: "Lost connection to the server", es: "Se perdió la conexión con el servidor")
    static let playbackTimeout = LString(en: "No data received from the server (timed out)", es: "No se recibieron datos del servidor (tiempo de espera agotado)")
    static let errorDetailLabel = LString(en: "Details", es: "Detalle")

    // Stats for nerds — friendly labels
    static let nsResolution = LString(en: "Resolution", es: "Resolución")
    static let nsVideo = LString(en: "Video", es: "Video")
    static let nsFps = LString(en: "Frames/sec", es: "Cuadros/seg")
    static let nsQuality = LString(en: "Video quality", es: "Calidad de video")
    static let nsDecoding = LString(en: "Decoding", es: "Decodificación")
    static let nsDecodeHardware = LString(en: "Hardware (fast)", es: "Hardware (rápido)")
    static let nsDecodeSoftware = LString(en: "Software", es: "Software")
    static let nsAudioSource = LString(en: "Audio (source)", es: "Audio (origen)")
    static let nsAudioOutput = LString(en: "Audio output", es: "Salida de audio")
    static let nsAudioEngine = LString(en: "Audio engine", es: "Motor de audio")
    static let nsChannels = LString(en: "ch", es: "canales")
    static let nsDroppedFrames = LString(en: "Dropped frames", es: "Cuadros perdidos")
    static let nsBuffer = LString(en: "Buffer", es: "Búfer")
    static let nsTorrent = LString(en: "Torrent", es: "Torrent")
    static let nsScreenFps = LString(en: "on screen", es: "en pantalla")

    // Smart Data (learned reputation, Settings)
    static let smartDataSection = LString(en: "Smart Data", es: "Smart Data")
    static let smartDataIntro = LString(
        en: "LumoraTV learns from real viewing: sources that load, get finished and whose embedded subtitles you actually use rank up; sources that fail or get abandoned rank down. This shapes the \"best source\" ranking.",
        es: "LumoraTV aprende de lo que realmente ves: las fuentes que cargan, se terminan y cuyos subtítulos embebidos usas suben; las que fallan o abandonas bajan. Esto alimenta el ranking de \"mejor fuente\"."
    )
    static let smartDataIndexers = LString(en: "Indexer reputation", es: "Reputación de indexers")
    static let smartDataUploaders = LString(en: "Uploader scores", es: "Score de uploaders")
    static let smartDataEmpty = LString(
        en: "No data yet — it builds up automatically as you watch.",
        es: "Aún no hay datos — se construyen automáticamente mientras ves contenido."
    )
    static let smartDataPlaybackStats = LString(
        en: "%d loads · %d finished · %d failures",
        es: "%d cargas · %d terminadas · %d fallos"
    )
    static let smartDataUploaderStats = LString(
        en: "%d loads · %d finished · %d subs used · %d subs rescued · %d failed/abandoned",
        es: "%d cargas · %d terminadas · %d subs usados · %d subs rescatados · %d fallos/abandonos"
    )
    static let smartDataReset = LString(en: "Reset all data", es: "Reiniciar todos los datos")
    static let smartDataResetTitle = LString(en: "Reset Smart Data?", es: "¿Reiniciar Smart Data?")
    static let smartDataResetMessage = LString(
        en: "All learned indexer and uploader reputation will be erased. The app will re-learn as you watch.",
        es: "Se borrará toda la reputación aprendida de indexers y uploaders. La app volverá a aprender mientras ves contenido."
    )

    // Modo Streaming (fuente externa de torrents) — antes "Descubrir"
    static let tabDiscover = LString(en: "Streaming Mode", es: "Modo Streaming")
    static let discoverSection = LString(en: "Streaming Mode (experimental)", es: "Modo Streaming (experimental)")
    static let trendingMovies = LString(en: "Trending Movies", es: "Películas en tendencia")
    static let popularShows = LString(en: "Popular Shows", es: "Series populares")
    static let trendingShows = LString(en: "Trending Shows", es: "Series en tendencia")
    static let topRatedMovies = LString(en: "Top Rated Movies", es: "Películas mejor valoradas")
    static let inTheaters = LString(en: "In Theaters", es: "En cine")
    static let upcoming = LString(en: "Coming Soon", es: "Próximos estrenos")
    static let inTheatersNow = LString(en: "Now in theaters", es: "En cartelera")
    static let theatricalRelease = LString(en: "Theatrical release", es: "Estreno en cine")
    static let digitalRelease = LString(en: "Digital release", es: "Estreno digital")
    static let digitalTBD = LString(en: "Digital release date not yet announced", es: "Fecha de estreno digital aún por anunciar")

    // FluxTorrent dashboard
    static let tabFluxTorrent = LString(en: "FluxTorrent", es: "FluxTorrent")
    static let fxDownloading = LString(en: "Downloading", es: "Bajando")
    static let fxSeeding = LString(en: "Seeding", es: "Sembrando")
    static let fxTorrents = LString(en: "torrents", es: "torrents")
    static let fxUploading = LString(en: "Uploading", es: "Subiendo")
    static let fxDownRate = LString(en: "Down rate", es: "Bajada")
    static let fxUpRate = LString(en: "Up rate", es: "Subida")
    static let fxActiveLimit = LString(en: "Active", es: "Activos")
    static let fxDisk = LString(en: "Disk", es: "Disco")
    static let fxUsed = LString(en: "used", es: "usados")
    static let fxFree = LString(en: "free", es: "libres")
    static let fxOf = LString(en: "of", es: "de")
    static let fxNoTorrents = LString(en: "No active torrents", es: "No hay torrents activos")
    static let fxAdded = LString(en: "Added", es: "Agregado")
    static let fxSeedTime = LString(en: "Seed time", es: "Tiempo de seed")
    static let fxSeedRatio = LString(en: "Seed ratio", es: "Ratio de seed")
    static let fxUploaded = LString(en: "Uploaded", es: "Subido")
    static let fxPeers = LString(en: "Peers", es: "Peers")
    static let fxTrackers = LString(en: "Trackers", es: "Trackers")

    static let enableDiscover = LString(en: "Enable Streaming Mode", es: "Activar Modo Streaming")
    static let prowlarrURLLabel = LString(en: "Prowlarr URL", es: "URL de Prowlarr")
    static let prowlarrKeyLabel = LString(en: "Prowlarr API key", es: "API key de Prowlarr")
    static let torrServerURLLabel = LString(en: "TorrServer URL", es: "URL de TorrServer")
    static let discoverDisclaimer = LString(
        en: "Streaming Mode plays from external sources (torrents) via Prowlarr + TorrServer, which YOU install and configure on your own device. LumoraTV hosts, indexes and provides NO content — it only plays an HTTP URL produced by your own infrastructure. Accessing or streaming copyright-protected material without authorization is ILLEGAL in most countries and may carry civil or criminal liability. You are the SOLE party responsible for what you search, index and play, and for complying with the laws of your jurisdiction. This is dual-use technology, offered only for content you own or are authorized to use. By enabling it you acknowledge that LumoraTV and its authors are unaffiliated with the services you connect and accept no liability whatsoever for your use.",
        es: "El Modo Streaming reproduce desde fuentes externas (torrents) vía Prowlarr + TorrServer, que TÚ instalas y configuras en tu propio dispositivo. LumoraTV no aloja, no indexa y no provee ningún contenido — solo reproduce una URL HTTP generada por tu propia infraestructura. Acceder o transmitir material protegido por derechos de autor sin autorización es ILEGAL en la mayoría de los países y puede acarrear responsabilidad civil o penal. Eres el ÚNICO responsable de lo que buscas, indexas y reproduces, y de cumplir las leyes de tu jurisdicción. Es tecnología de doble uso, ofrecida únicamente para contenido que poseas o cuyo uso esté autorizado. Al activarlo aceptas que LumoraTV y sus autores no tienen relación con los servicios que conectes y no asumen ninguna responsabilidad por el uso que le des."
    )
    static let noSourcesConfigured = LString(
        en: "No playback sources found. Connect a server in Settings, or enable Streaming Mode to play from torrents.",
        es: "No se encontraron fuentes para reproducir. Conecta un servidor en Ajustes, o activa el Modo Streaming para reproducir desde torrents."
    )
    static let searchingReleases = LString(en: "Searching releases…", es: "Buscando releases…")
    static let noReleases = LString(en: "No releases found", es: "No se encontraron releases")
    static let preparingStream = LString(en: "Preparing stream…", es: "Preparando reproducción…")
    static let seedersLabel = LString(en: "seeders", es: "seeders")
    static let torrentConnecting = LString(en: "Connecting to the torrent…", es: "Conectando al torrent…")
    static let torrentFindingPeers = LString(en: "Finding peers…", es: "Buscando pares…")
    static let torrentBuffering = LString(en: "Buffering…", es: "Cargando búfer…")
    static let torrentPeers = LString(en: "peers", es: "pares")
    static let torrentReady = LString(en: "Almost ready…", es: "Casi listo…")
    static let refresh = LString(en: "Refresh", es: "Refrescar")
    static let openSubtitlesNotConfigured = LString(
        en: "Set up OpenSubtitles in Settings to search and download subtitles.",
        es: "Configura OpenSubtitles en Ajustes para buscar y descargar subtítulos."
    )
    static let osHint = LString(
        en: "All three are required. The API Key identifies the app — get a free one at opensubtitles.com → Consumers (API). The username and password are your opensubtitles.com account, needed to download (free accounts have a daily quota).",
        es: "Se requieren los tres. La API Key identifica la app — obtén una gratis en opensubtitles.com → Consumers (API). El usuario y la contraseña son tu cuenta de opensubtitles.com, necesarios para descargar (las cuentas gratis tienen un límite diario)."
    )
    static let playerInfoGroup = LString(en: "Player info", es: "Información en el reproductor")
    static let showClock = LString(en: "Current time", es: "Hora actual")
    static let showDate = LString(en: "Date", es: "Fecha")
    static let showPG = LString(en: "Content rating (PG)", es: "Clasificación (PG)")
    static let showGenres = LString(en: "Genres", es: "Géneros")
    static let showRatingStar = LString(en: "Rating", es: "Calificación")
    static let showYearLabel = LString(en: "Year", es: "Año")
    static let showQuality = LString(en: "Quality (4K · HDR)", es: "Calidad (4K · HDR)")
    static let showCurrentAudio = LString(en: "Current audio", es: "Audio actual")
    static let showCurrentSubtitle = LString(en: "Current subtitle", es: "Subtítulo actual")
    static let suggestNextEpisode = LString(en: "Suggest next episode", es: "Sugerir siguiente episodio")
    /// Series progress line: episodes left, e.g. "5 episodes left" / "Faltan 5 capítulos".
    static let episodesLeftShort = LString(en: "%d left", es: "faltan %d")
    static let episodesLeftLong = LString(en: "%d episodes left", es: "Faltan %d capítulos")
    static let seriesFinish = LString(en: "Finish", es: "Finalizar")
    // Picture / color mode
    static let colorModeGroup = LString(en: "Picture mode", es: "Modo de imagen")
    static let colorModeNormal = LString(en: "Normal", es: "Normal")
    static let colorModeSleep = LString(en: "Sleep", es: "Dormir")
    static let colorModeVivid = LString(en: "Vivid", es: "Vivos")
    static let colorModeNoir = LString(en: "Noir", es: "Noir")
    // Language-learning mode
    static let learningModeGroup = LString(en: "Learning mode", es: "Modo aprendizaje")
    static let learningModeToggle = LString(en: "Learn while watching", es: "Aprender mientras ves")
    static let learningTellMeMore = LString(en: "What was said?", es: "¿Qué dijeron?")
    static let learningNewWord = LString(en: "new", es: "nueva")
    static let learningReplayLine = LString(en: "Replay line", es: "Repetir frase")
    static let learningPlayLine = LString(en: "Listen", es: "Escuchar")
    static let learningSummaryTitle = LString(en: "What you picked up", es: "Lo que aprendiste")
    static let learningWordsNew = LString(en: "%d new words", es: "%d palabras nuevas")
    static let learningComprehension = LString(en: "Comprehension: %d%%", es: "Comprensión: %d%%")
    static let learningReplayHint = LString(en: "Select a line to explore it · Back to close", es: "Selecciona una frase para explorarla · Atrás para cerrar")
    static let learningTapWord = LString(en: "Tap a word for its meaning", es: "Toca una palabra para ver su significado")
    static let learningReplayPhrase = LString(en: "Replay line", es: "Repetir frase")
    static let learningListenPhrase = LString(en: "Listen", es: "Escuchar")
    // AI section
    static let aiSection = LString(en: "Artificial Intelligence", es: "Inteligencia Artificial")
    static let aiProviderLabel = LString(en: "Provider", es: "Proveedor")
    static let aiModelLabel = LString(en: "Model", es: "Modelo")
    static let aiKeyLabel = LString(en: "API key", es: "Clave API (API key)")
    static let aiBaseURLLabel = LString(en: "Base URL", es: "URL base")
    static let aiProviderCustom = LString(en: "Custom / local", es: "Personalizado / local")
    static let aiValidate = LString(en: "Validate & load models", es: "Validar y cargar modelos")
    static let aiModelsLoading = LString(en: "Loading models…", es: "Cargando modelos…")
    static let aiModelsError = LString(en: "Couldn't load models. Check the key/URL.", es: "No se pudieron cargar los modelos. Revisa la key/URL.")
    static let aiKeyValid = LString(en: "Valid · %d models", es: "Válida · %d modelos")
    static let aiSelectModel = LString(en: "Select a model", es: "Elige un modelo")
    static let aiModelTip = LString(
        en: "Tip: for language explanations a small, economical model is plenty (e.g. gpt-4o-mini, gemini-2.0-flash, llama-3.x) — fast and cheap. You don't need a large model.",
        es: "Tip: para explicar palabras/frases basta un modelo económico (p. ej. gpt-4o-mini, gemini-2.0-flash, llama-3.x): rápido y barato. No necesitas uno grande."
    )
    static let aiIntro = LString(en: "Used by learning mode to explain words. Any OpenAI-compatible provider works.", es: "Lo usa el modo aprendizaje para explicar palabras. Sirve cualquier proveedor compatible con OpenAI.")
    static let aiThinking = LString(en: "Thinking…", es: "Pensando…")
    static let aiNotConfigured = LString(en: "Set up an AI provider in Settings → Artificial Intelligence.", es: "Configura un proveedor de IA en Ajustes → Inteligencia Artificial.")
    static let aiFailed = LString(en: "Couldn't get an explanation. Check your AI settings.", es: "No se pudo obtener la explicación. Revisa tu configuración de IA.")
    static let audioGroup = LString(en: "Audio output", es: "Salida de audio")
    static let passthroughLabel = LString(en: "AC3/E-AC3 passthrough (experimental)", es: "Passthrough AC3/E-AC3 (experimental)")
    static let passthroughHint = LString(
        en: "If your system rejects it, audio falls back to multichannel PCM automatically.",
        es: "Si el sistema lo rechaza, el audio vuelve a PCM multicanal automáticamente."
    )

    // Service errors & diagnostics (connection tests, source resolution)
    static let keyValid = LString(en: "Valid key", es: "Clave válida")
    static let keyInvalid = LString(en: "Invalid key or no connection.", es: "Clave inválida o sin conexión.")
    static let invalidURL = LString(en: "Invalid URL.", es: "URL inválida.")
    static let noResponse = LString(en: "No response (URL/network?).", es: "Sin respuesta (¿URL/red?).")
    static let httpCodeCheckKey = LString(en: "HTTP %d (API key/URL?).", es: "HTTP %d (¿API key/URL?).")
    static let prowlarrNotConfigured = LString(en: "Prowlarr is not configured.", es: "Prowlarr no está configurado.")
    static let prowlarrBadURL = LString(en: "Invalid Prowlarr URL.", es: "URL de Prowlarr inválida.")
    static let prowlarrHTTPError = LString(
        en: "HTTP %d from Prowlarr (wrong URL or API key?).",
        es: "HTTP %d de Prowlarr (¿URL o API key incorrecta?)."
    )
    static let prowlarrNoReleases = LString(
        en: "Prowlarr returned no releases for “%@”. Check that you have indexers enabled.",
        es: "Prowlarr no devolvió releases para «%@». Revisa que tengas indexers habilitados."
    )
    static let episodeNotFound = LString(
        en: "Episode %@ not found (nor a pack containing it). Try another season or enable more indexers.",
        es: "No se encontró el episodio %@ (ni un pack que lo incluya). Prueba otra temporada o habilita más indexers."
    )
    static let streamingIncomplete = LString(
        en: "Streaming Mode incomplete — missing: %@.",
        es: "Modo Streaming incompleto — falta configurar: %@."
    )
    static let torrServerNotConfigured = LString(en: "TorrServer is not configured.", es: "TorrServer no está configurado.")
    static let torrServerAddFailed = LString(en: "TorrServer could not add the torrent.", es: "TorrServer no pudo añadir el torrent.")
    static let torrServerBadConfig = LString(
        en: "TorrServer not configured or invalid URL.",
        es: "TorrServer sin configurar o URL inválida."
    )
    static let playbackBuildFailed = LString(en: "Could not build playback.", es: "No se pudo construir la reproducción.")
    static let osLoginFailed = LString(en: "Could not sign in to OpenSubtitles.", es: "No se pudo iniciar sesión en OpenSubtitles.")
    static let osSearchFailed = LString(en: "Subtitle search failed.", es: "No se pudieron buscar subtítulos.")
    static let osDownloadFailed = LString(en: "Could not download the subtitle.", es: "No se pudo descargar el subtítulo.")
    static let osQuota = LString(
        en: "You reached OpenSubtitles' daily download limit.",
        es: "Alcanzaste el límite diario de descargas de OpenSubtitles."
    )
    static let osMissingCreds = LString(en: "Missing API key, username or password.", es: "Falta API key, usuario o contraseña.")
    static let osLoggedInAs = LString(en: "Signed in as %@", es: "Sesión iniciada como %@")
    static let osLoginCheck = LString(
        en: "Could not sign in (API key or credentials?).",
        es: "No se pudo iniciar sesión (¿API key o credenciales?)."
    )
    static let torrentCompressed = LString(
        en: "This release is compressed (RAR/ZIP) and can't be played directly. Try another source.",
        es: "Este release viene comprimido (RAR/ZIP) y no se puede reproducir directamente. Prueba otra fuente."
    )
    static let torrentMetadataTimeout = LString(
        en: "Couldn't get the torrent's file list (no metadata). Usually a lack of seeders; try another source.",
        es: "No se pudo obtener la lista de archivos del torrent (sin metadatos). Suele faltar semillas; prueba otra fuente."
    )
    static let tmdbKeyMissing = LString(en: "Missing TMDB API key.", es: "Falta la API key de TMDB.")
    static let speedNoSample = LString(en: "No content to measure on this server.", es: "No hay contenido para medir en este servidor.")
    static let speedFailed = LString(en: "Could not measure speed.", es: "No se pudo medir la velocidad.")
    static let serverBadResponse = LString(en: "Unexpected server response.", es: "Respuesta inesperada del servidor.")
    static let serverUnreachable = LString(en: "Could not connect to the server.", es: "No se pudo conectar con el servidor.")
    static let sourceFailedTrying = LString(
        en: "Source failed — trying %@…",
        es: "La fuente falló — probando %@…"
    )

    // Stats for nerds
    static let nerdStatsLabel = LString(en: "Stats for nerds", es: "Stats para nerds")

    // Top 10 / collections / new episodes
    static let top10Title = LString(en: "Top 10 Today", es: "Top 10 de hoy")
    static let sagaTitle = LString(en: "Collection", es: "Saga")
    static let newEpisodeLabel = LString(en: "NEW · S%d E%d", es: "NUEVO · T%d E%d")

    // iCloud sync
    static let syncTitle = LString(en: "Sync", es: "Sincronización")
    static let syncActive = LString(en: "Active (iCloud)", es: "Activa (iCloud)")
    static let syncSyncing = LString(en: "Syncing…", es: "Sincronizando…")
    static let syncUnavailable = LString(en: "Sign in to iCloud to sync", es: "Inicia sesión en iCloud para sincronizar")
    static let syncDisabled = LString(en: "Available with iCloud", es: "Disponible con iCloud")
    static let syncFindConfig = LString(en: "Look for my devices' setup", es: "Buscar la configuración de mis equipos")
    static let syncPerUserHint = LString(
        en: "For per-person sync across TVs, each Apple TV user must sign in with their own Apple ID. Profiles sharing one Apple ID can't be kept separate.",
        es: "Para sincronizar por persona entre TVs, cada usuario del Apple TV debe iniciar sesión con su propio Apple ID. Los perfiles que comparten un Apple ID no pueden mantenerse separados.")
    // Perfiles propios de la app
    static let profileWhoWatching = LString(en: "Who's watching?", es: "¿Quién está viendo?")
    static let profileAdd = LString(en: "Add profile", es: "Agregar perfil")
    static let profileManage = LString(en: "Manage profiles", es: "Administrar perfiles")
    static let profileDone = LString(en: "Done", es: "Listo")
    static let profileNew = LString(en: "New profile", es: "Nuevo perfil")
    static let profileEdit = LString(en: "Edit profile", es: "Editar perfil")
    static let profileName = LString(en: "Name", es: "Nombre")
    static let profileNamePlaceholder = LString(en: "Profile name", es: "Nombre del perfil")
    static let profileKid = LString(en: "Kids profile", es: "Perfil de niños")
    static let profileKidHint = LString(en: "Shows only age-appropriate content", es: "Solo muestra contenido apropiado para su edad")
    static let profileColor = LString(en: "Color", es: "Color")
    static let profileAvatar = LString(en: "Avatar", es: "Avatar")
    static let profileLevel = LString(en: "Age limit", es: "Límite de edad")
    static let profileSave = LString(en: "Save", es: "Guardar")
    static let profileCancel = LString(en: "Cancel", es: "Cancelar")
    static let profileDelete = LString(en: "Delete profile", es: "Eliminar perfil")
    static let profileDeleteConfirm = LString(en: "Delete this profile?", es: "¿Eliminar este perfil?")
    static let profileDeleteMsg = LString(en: "Its watch history, list and settings on this Apple TV will be removed.", es: "Se eliminará su historial, lista y ajustes en este Apple TV.")
    static let profileSwitch = LString(en: "Switch profile", es: "Cambiar perfil")
    static let profilePushTitle = LString(en: "Upload this Apple TV to iCloud", es: "Subir este Apple TV a iCloud")
    static let profilePushHint = LString(
        en: "Manually uploads everything on this device — every profile and its watch history, continue watching, lists and ratings — as a safety backup. Normal sync already happens automatically as you play, pause and add.",
        es: "Sube manualmente todo lo de este equipo —cada perfil y su historial, continuar viendo, listas y valoraciones— como respaldo de seguridad. La sincronización normal ya ocurre sola al reproducir, pausar y agregar.")
    static let profilePushConfirm = LString(en: "Upload everything now?", es: "¿Subir todo ahora?")
    static let pushAllChecking = LString(en: "Checking iCloud…", es: "Comprobando iCloud…")
    static let pushAllProfile = LString(en: "Uploading %@ (%d of %d)…", es: "Subiendo %@ (%d de %d)…")
    static let pushAllDone = LString(en: "Uploaded %d profiles · %d items", es: "Subidos %d perfiles · %d elementos")
    static let profilePinEnter = LString(en: "Enter household PIN", es: "Ingresa el PIN del hogar")
    static let profilePinCreate = LString(en: "Create a household PIN", es: "Crea un PIN del hogar")
    static let profilePinHint = LString(en: "Protects adult profiles and profile management", es: "Protege los perfiles de adulto y la administración")
    static let profilePinWrong = LString(en: "Wrong PIN", es: "PIN incorrecto")
    static let profilePinSkip = LString(en: "No PIN", es: "Sin PIN")
    // Toasts de sincronización iCloud (solo build de pago)
    static let toastSyncDown = LString(en: "Synced from iCloud", es: "Sincronizado desde iCloud")
    static let toastConfigDown = LString(en: "Setup received from another device", es: "Configuración recibida de otro equipo")
    static let toastConfigUp = LString(en: "Setup uploaded to iCloud", es: "Configuración enviada a iCloud")
    static let toastSyncFailed = LString(en: "iCloud sync failed", es: "Error al sincronizar con iCloud")
    static let toastNoICloud = LString(en: "Sign in to iCloud to sync", es: "Sin iCloud: inicia sesión para sincronizar")
    static let parentalBlocked = LString(en: "Blocked by Parental Controls", es: "Bloqueado por el control parental")
    static let homeLoading = LString(en: "Loading your home…", es: "Cargando tu inicio…")
    static let syncLastAt = LString(en: "Last sync: %@", es: "Última sincronización: %@")
    static let syncNever = LString(en: "Never", es: "Nunca")

    // Social (Trakt community panel)
    static let communityComments = LString(en: "Community comments", es: "Comentarios de la comunidad")
    static let communityLoading = LString(en: "Loading comments…", es: "Cargando comentarios…")
    static let communityNoComments = LString(en: "No comments yet for this title.", es: "Aún no hay comentarios para este título.")
    static let communityHint = LString(en: "From Trakt · shown in their original language, your language first", es: "De Trakt · en su idioma original, el tuyo primero")
    static let spoilerReveal = LString(en: "Spoiler — select to reveal", es: "Spoiler — selecciona para ver")
    static let traktSection = LString(en: "Community (Trakt)", es: "Comunidad (Trakt)")
    static let traktClientID = LString(en: "Trakt Client ID", es: "Client ID de Trakt")
    static let traktHint = LString(en: "Register a free app at trakt.tv/oauth/applications and paste its Client ID to read community comments.", es: "Registra una app gratis en trakt.tv/oauth/applications y pega su Client ID para ver los comentarios de la comunidad.")
    static let traktClientSecret = LString(en: "Trakt Client Secret", es: "Client Secret de Trakt")
    static let traktConnect = LString(en: "Connect my Trakt account", es: "Conectar mi cuenta de Trakt")
    static let traktConnectPerUser = LString(en: "Per Apple TV user — each profile links its own account.", es: "Por usuario de Apple TV — cada perfil enlaza su propia cuenta.")
    static let traktConnected = LString(en: "Connected", es: "Conectada")
    static let traktDisconnect = LString(en: "Disconnect", es: "Desconectar")
    static let traktConnecting = LString(en: "Waiting for authorization…", es: "Esperando autorización…")
    static let traktLinkScan = LString(en: "Scan with your phone, or go to %@ and enter:", es: "Escanea con tu teléfono, o entra a %@ y escribe:")
    static let traktLinkError = LString(en: "Couldn't complete the connection. Check the Client ID and Secret.", es: "No se pudo completar la conexión. Revisa el Client ID y el Secret.")
    static let traktNeedsSecret = LString(en: "Add the Client Secret to connect your account.", es: "Agrega el Client Secret para conectar tu cuenta.")
    static let communityTrending = LString(en: "Trending in the community", es: "Tendencias en la comunidad")
    static let communityMostWatched = LString(en: "Most watched now", es: "Lo más visto ahora")
    static let communityAnticipated = LString(en: "Most anticipated", es: "Lo más esperado")
    static let traktWriteComment = LString(en: "Write a comment", es: "Escribir un comentario")
    static let traktCommentPlaceholder = LString(en: "Your comment (min. 5 words)…", es: "Tu comentario (mín. 5 palabras)…")
    static let traktMarkSpoiler = LString(en: "Mark as spoiler", es: "Marcar como spoiler")
    static let traktTypeFromPhone = LString(en: "Have an iPhone nearby? You can type from it.", es: "¿Tienes un iPhone cerca? Puedes escribir desde él.")
    static let post = LString(en: "Post", es: "Publicar")
}
