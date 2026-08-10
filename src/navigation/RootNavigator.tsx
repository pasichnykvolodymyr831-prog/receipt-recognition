import { Ionicons } from "@expo/vector-icons";
import { NavigationContainer } from "@react-navigation/native";
import { createBottomTabNavigator } from "@react-navigation/bottom-tabs";
import React from "react";
import { useTranslation } from "react-i18next";
import DrivingDetailsScreen from "../screens/DrivingDetailsScreen";
import ExpenseReportScreen from "../screens/ExpenseReportScreen";
import HomeScreen from "../screens/HomeScreen";
import SettingsScreen from "../screens/SettingsScreen";
import TimesheetScreen from "../screens/TimesheetScreen";

export type RootTabParamList = {
  Home: undefined;
  Timesheet: undefined;
  Expenses: undefined;
  Driving: undefined;
  Settings: undefined;
};

const Tab = createBottomTabNavigator<RootTabParamList>();

const TAB_ICONS: Record<keyof RootTabParamList, keyof typeof Ionicons.glyphMap> = {
  Home: "home-outline",
  Timesheet: "time-outline",
  Expenses: "receipt-outline",
  Driving: "car-outline",
  Settings: "settings-outline",
};

export default function RootNavigator() {
  const { t } = useTranslation();

  return (
    <NavigationContainer>
      <Tab.Navigator
        screenOptions={({ route }) => ({
          headerShown: false,
          tabBarIcon: ({ color, size }) => (
            <Ionicons name={TAB_ICONS[route.name as keyof RootTabParamList]} size={size} color={color} />
          ),
        })}
      >
        <Tab.Screen name="Home" component={HomeScreen} options={{ title: t("nav.home") }} />
        <Tab.Screen name="Timesheet" component={TimesheetScreen} options={{ title: t("nav.timesheet") }} />
        <Tab.Screen name="Expenses" component={ExpenseReportScreen} options={{ title: t("nav.expenses") }} />
        <Tab.Screen name="Driving" component={DrivingDetailsScreen} options={{ title: t("nav.driving") }} />
        <Tab.Screen name="Settings" component={SettingsScreen} options={{ title: t("nav.settings") }} />
      </Tab.Navigator>
    </NavigationContainer>
  );
}
