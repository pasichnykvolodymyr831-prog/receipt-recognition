// eslint-disable-next-line @typescript-eslint/no-var-requires
const { getDefaultConfig } = require("expo/metro-config");

const config = getDefaultConfig(__dirname);

// Bundle the .xlsx company templates as binary assets (like a font or
// image) so expo-asset can resolve them to a local file URI at runtime -
// Metro doesn't treat .xlsx as an asset type by default.
config.resolver.assetExts = [...config.resolver.assetExts, "xlsx"];

module.exports = config;
