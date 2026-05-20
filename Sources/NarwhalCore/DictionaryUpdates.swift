extension Dictionary {
    func setting(_ key: Key, to value: Value) -> [Key: Value] {
        merging([key: value]) { _, replacement in replacement }
    }

    func removing(_ key: Key) -> [Key: Value] {
        filter { $0.key != key }
    }

    func settingOrRemoving(_ key: Key, to value: Value?) -> [Key: Value] {
        guard let value else { return removing(key) }
        return setting(key, to: value)
    }
}
