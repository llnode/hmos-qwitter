import { Configuration, ConfigurationConstant, UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { followDeviceLanguage, initializeLanguages } from './i18n/LanguageSettings';
import { initializeMediaPreferences } from './data/MediaPreferences';
import { initializeAppearancePreferences, updateAccentInk } from './data/AppearancePreferences';
import { LAUNCHER_ICON_STORAGE_KEY, readLauncherIcon } from './data/LauncherIconChoices';

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;
  private keyboardHeightChanged = (height: number): void => {
    const current = this.mainWindow;
    if (current) AppStorage.setOrCreate('qyxKeyboardInset', current.getUIContext().px2vp(Math.max(0, height)));
  };
  private safeAreaChanged = (): void => { this.updateInsets(); };

  onForeground(): void {
    AppStorage.setOrCreate('qyxForeground', true);
    this.updateBars(this.context.config.colorMode);
  }

  onBackground(): void {
    AppStorage.setOrCreate('qyxForeground', false);
  }

  onConfigurationUpdate(configuration: Configuration): void {
    this.updateBars(configuration.colorMode);
    followDeviceLanguage(this.context);
    this.updateInsets();
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    try {
      this.mainWindow = stage.getMainWindowSync();
      this.mainWindow.on('avoidAreaChange', this.safeAreaChanged);
      AppStorage.setOrCreate('qyxKeyboardInset', 0);
      this.mainWindow.on('keyboardHeightChange', this.keyboardHeightChanged);
      this.mainWindow.setWindowLayoutFullScreen(true).then(() => {
        this.updateInsets();
        this.updateBars(this.context.config.colorMode);
      }).catch(() => {});
      this.updateInsets();
      this.updateBars(this.context.config.colorMode);
    } catch (_) {
      // Keep the default window if system bar configuration is unavailable.
    }
    initializeLanguages(this.context);
    initializeMediaPreferences(this.context);
    initializeAppearancePreferences(this.context);
    readLauncherIcon().then((id: string) => {
      AppStorage.setOrCreate(LAUNCHER_ICON_STORAGE_KEY, id);
    }).catch(() => {
      const current = AppStorage.get<string>(LAUNCHER_ICON_STORAGE_KEY);
      if (current === undefined || current === 'pending') {
        AppStorage.setOrCreate(LAUNCHER_ICON_STORAGE_KEY, '');
      }
    });
    stage.loadContent('pages/Index', () => this.updateInsets());
  }

  onWindowStageDestroy(): void {
    this.mainWindow?.off('avoidAreaChange', this.safeAreaChanged);
    this.mainWindow?.off('keyboardHeightChange', this.keyboardHeightChanged);
    AppStorage.setOrCreate('qyxKeyboardInset', 0);
    this.mainWindow = undefined;
  }

  private updateBars(mode?: ConfigurationConstant.ColorMode): void {
    const dark = mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    updateAccentInk(dark);
    const content = dark ? '#FFEFF3F4' : '#FF0F1419';
    this.mainWindow?.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: content,
      navigationBarContentColor: content
    }).catch(() => {});
  }

  private updateInsets(): void {
    const current = this.mainWindow;
    if (!current) return;
    try {
      const system = current.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const cutout = current.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const navigation = current.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const ui = current.getUIContext();
      AppStorage.setOrCreate('qyxStatusInset', ui.px2vp(Math.max(system.topRect.height,
        cutout.topRect.top + cutout.topRect.height)));
      AppStorage.setOrCreate('qyxBottomInset', ui.px2vp(Math.max(system.bottomRect.height, navigation.bottomRect.height)));
    } catch (_) {
      // The first layout callback retries once UIContext is ready.
    }
  }
}
