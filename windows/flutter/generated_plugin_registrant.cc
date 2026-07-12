//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <mpv_audio_kit/mpv_audio_kit_plugin_c_api.h>
#include <permission_handler_windows/permission_handler_windows_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  MpvAudioKitPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("MpvAudioKitPluginCApi"));
  PermissionHandlerWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("PermissionHandlerWindowsPlugin"));
}
