import Foundation

struct SettingsStore {
    private let defaults: UserDefaults
    private let storageKey = "translator.app-settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: storageKey) else {
            return .makeDefault()
        }

        do {
            var settings = try JSONDecoder().decode(AppSettings.self, from: data)
            settings.normalizeSelections()
            return settings
        } catch {
            // Keep a corrupt value for troubleshooting while allowing the app to recover.
            defaults.set(data, forKey: storageKey + ".corrupt")
            return .makeDefault()
        }
    }

    func save(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: storageKey)
    }
}
