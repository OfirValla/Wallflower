import '../models/aura_settings.dart';

/// Persistence boundary for [AuraSettings].
///
/// The domain layer depends on this interface, never on `shared_preferences`
/// or the keystore. That is what makes the presentation layer testable with a
/// two-line in-memory fake, and what would let the storage swap to Room-style
/// SQLite (via `drift`) if settings ever grow history or multi-profile support.
abstract interface class SettingsRepository {
  Future<AuraSettings> load();

  Future<void> save(AuraSettings settings);

  Future<void> reset();
}
