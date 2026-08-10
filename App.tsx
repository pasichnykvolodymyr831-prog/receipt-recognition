import "./src/i18n";
import React from "react";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { AppSettingsProvider } from "./src/context/AppSettingsContext";
import RootNavigator from "./src/navigation/RootNavigator";

export default function App() {
  return (
    <SafeAreaProvider>
      <AppSettingsProvider>
        <RootNavigator />
      </AppSettingsProvider>
    </SafeAreaProvider>
  );
}
