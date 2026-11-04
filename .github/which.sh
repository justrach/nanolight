echo "sw_vers:"; sw_vers
echo "--- missing among the ten ---"
for a in "Wi-Fi" "Bluetooth" "Network" "Sound" "GeneralSettings" "Appearance" "KeyboardSettings" "DisplaysExt" "LoginItems" "SecurityPrivacyExtension"; do
  if [ -e "/System/Library/ExtensionKit/Extensions/$a.appex" ]; then echo "have $a"; else echo "MISSING $a"; fi
done
echo "--- all extensions ---"
ls /System/Library/ExtensionKit/Extensions/ | sed 's/\.appex$//' | sort | tr '\n' '|'
