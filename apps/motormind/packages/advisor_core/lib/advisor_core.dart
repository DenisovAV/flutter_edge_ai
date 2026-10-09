/// Motormind's model-agnostic conversation core: tool specs, the turn
/// pipeline, the number guards, policy and disclosures, the buyer profile,
/// the system prompt builder, the UI component registry and vehicle search
/// and reading.
///
/// Two conventions hold throughout. `toJson` is the hand-off form for the
/// model and the UI, not a storage format: only `ReadingRecipe`, `FieldRule`,
/// `SelfCheckRules` and `SelfCheck` round-trip through their `fromJson`,
/// because recipes and captures are kept on disk. And nothing under `src/`
/// imports Flutter, so every type here runs in a plain `dart test`.
library;

export 'src/guard/input_guard.dart';
export 'src/guard/narration_guard.dart';
export 'src/pipeline/chat_driver.dart';
export 'src/pipeline/turn_pipeline.dart';
export 'src/policy/disclosures.dart';
export 'src/policy/policy_check.dart';
export 'src/profile/buyer_profile.dart';
export 'src/prompt/system_prompt.dart';
export 'src/tools/finance_tool_handlers.dart';
export 'src/tools/tool_spec.dart';
export 'src/ui/ui_spec.dart';
export 'src/vehicles/curated_sites.dart';
export 'src/vehicles/listing.dart';
export 'src/vehicles/listing_extractor.dart';
export 'src/vehicles/listing_store.dart';
export 'src/vehicles/reading_recipe.dart';
export 'src/vehicles/search_query.dart';
