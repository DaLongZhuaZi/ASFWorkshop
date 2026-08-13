import {
  NGFImmersiveTopChromePresetFactory,
  NGFImmersiveTopChromeSpec
} from 'ngf_framework';

export class SteamArkTheme {
  static readonly CONTENT_TOP_INSET: number = 92;
  static readonly CONTENT_BOTTOM_INSET: number = 92;

  // These tokens are selected from the reactive theme state instead of relying
  // only on resource qualifiers. This also keeps an in-app light/dark override
  // synchronized with HDS title bars and custom Button content.
  static background(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_background')
      : $r('app.color.steam_ark_theme_light_background');
  }

  static surface(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_surface')
      : $r('app.color.steam_ark_theme_light_surface');
  }

  static surfaceElevated(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_surface_elevated')
      : $r('app.color.steam_ark_theme_light_surface_elevated');
  }

  static surfaceControl(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_surface_control')
      : $r('app.color.steam_ark_theme_light_surface_control');
  }

  static surfaceOverlay(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_surface_overlay')
      : $r('app.color.steam_ark_theme_light_surface_overlay');
  }

  static accent(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_accent')
      : $r('app.color.steam_ark_theme_light_accent');
  }

  static accentCyan(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_accent_cyan')
      : $r('app.color.steam_ark_theme_light_accent_cyan');
  }

  static onAccent(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_on_accent')
      : $r('app.color.steam_ark_theme_light_on_accent');
  }

  static buttonForeground(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_button_foreground')
      : $r('app.color.steam_ark_theme_light_button_foreground');
  }

  static buttonDisabled(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_button_disabled')
      : $r('app.color.steam_ark_theme_light_button_disabled');
  }

  static buttonDisabledText(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_button_disabled_text')
      : $r('app.color.steam_ark_theme_light_button_disabled_text');
  }

  static success(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_success')
      : $r('app.color.steam_ark_theme_light_success');
  }

  static warning(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_warning')
      : $r('app.color.steam_ark_theme_light_warning');
  }

  static textPrimary(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_text_primary')
      : $r('app.color.steam_ark_theme_light_text_primary');
  }

  static textSecondary(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_text_secondary')
      : $r('app.color.steam_ark_theme_light_text_secondary');
  }

  static textMuted(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_text_muted')
      : $r('app.color.steam_ark_theme_light_text_muted');
  }

  static divider(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_divider')
      : $r('app.color.steam_ark_theme_light_divider');
  }

  static error(isDarkMode: boolean): ResourceColor {
    return isDarkMode
      ? $r('app.color.steam_ark_theme_dark_error')
      : $r('app.color.steam_ark_theme_light_error');
  }

  static buildTopChrome(isDarkMode: boolean): NGFImmersiveTopChromeSpec {
    if (isDarkMode) {
      return NGFImmersiveTopChromePresetFactory.build(
        $r('app.color.steam_ark_chrome_dark_start'),
        $r('app.color.steam_ark_chrome_dark_mid'),
        $r('app.color.steam_ark_chrome_dark_end'),
        $r('app.color.steam_ark_chrome_dark_primary'),
        $r('app.color.steam_ark_chrome_dark_secondary'),
        168,
        SteamArkTheme.CONTENT_TOP_INSET
      );
    }
    return NGFImmersiveTopChromePresetFactory.build(
      $r('app.color.steam_ark_chrome_light_start'),
      $r('app.color.steam_ark_chrome_light_mid'),
      $r('app.color.steam_ark_chrome_light_end'),
      $r('app.color.steam_ark_chrome_light_primary'),
      $r('app.color.steam_ark_chrome_light_secondary'),
      168,
      SteamArkTheme.CONTENT_TOP_INSET
    );
  }
}
