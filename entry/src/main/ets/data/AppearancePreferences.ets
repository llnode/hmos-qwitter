import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { uiMaterial } from '@kit.ArkUI';

const STORE: string = 'qyx-appearance';
export const APPEARANCE_ROUTE: string = '/qwitter/appearance';
export const LANGUAGE_ROUTE: string = '/qwitter/language';
export const MEDIA_ROUTE: string = '/qwitter/media';
export const PRIVACY_ROUTE: string = '/qwitter/privacy';
export const TERMS_ROUTE: string = '/qwitter/terms';

export function isLocalSettingsRoute(route: string): boolean {
  return route === APPEARANCE_ROUTE || route === LANGUAGE_ROUTE || route === MEDIA_ROUTE ||
    route === PRIVACY_ROUTE || route === TERMS_ROUTE;
}
export const TAB_MATERIAL_STYLES: uiMaterial.ImmersiveStyle[] = [
  uiMaterial.ImmersiveStyle.ULTRA_THIN,
  uiMaterial.ImmersiveStyle.THIN,
  uiMaterial.ImmersiveStyle.REGULAR,
  uiMaterial.ImmersiveStyle.THICK,
  uiMaterial.ImmersiveStyle.ULTRA_THICK
];
export const DEFAULT_TAB_MATERIAL: number = 1;
export const TAB_HEIGHTS: number[] = [48, 56, 64];
export const DEFAULT_TAB_HEIGHT: number = 56;
export const DEFAULT_ACCENT: string = '#1685C7';

export class AccentChoice {
  constructor(name: string, color: string) {
    this.name = name;
    this.color = color;
  }
  readonly name: string;
  readonly color: string;
}

export const ACCENT_CHOICES: AccentChoice[] = [
  new AccentChoice('默认蓝', DEFAULT_ACCENT),
  new AccentChoice('科技蓝', '#007DFF'),
  new AccentChoice('电光蓝', '#0066FF'),
  new AccentChoice('天空蓝', '#00A7F5'),
  new AccentChoice('亮青', '#00B8D9'),
  new AccentChoice('翡翠', '#00B99A'),
  new AccentChoice('鲜绿', '#15B85A'),
  new AccentChoice('青柠', '#8BC900'),
  new AccentChoice('明黄', '#FFD000'),
  new AccentChoice('琥珀', '#FFAA00'),
  new AccentChoice('活力橙', '#FF7A00'),
  new AccentChoice('珊瑚', '#FF5A36'),
  new AccentChoice('朱红', '#FF3B4E'),
  new AccentChoice('玫红', '#FF2D78'),
  new AccentChoice('亮粉', '#F038B5'),
  new AccentChoice('洋红', '#CF38EF'),
  new AccentChoice('紫晶', '#963DFF'),
  new AccentChoice('鸢尾', '#7352FF'),
  new AccentChoice('靛蓝', '#4255FF')
];

function validAccent(color: string): boolean {
  return ACCENT_CHOICES.some((choice: AccentChoice) => choice.color === color);
}

function linearChannel(channel: number): number {
  const value = channel / 255;
  return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
}

function accentLuminance(rgb: number): number {
  return 0.2126 * linearChannel((rgb >> 16) & 255) +
    0.7152 * linearChannel((rgb >> 8) & 255) + 0.0722 * linearChannel(rgb & 255);
}

// Text and icons on an accent fill. White whenever it reaches 3:1 contrast (WCAG minimum for large text and UI
// controls), black otherwise. The previous midpoint rule chose black for most accents, including the default blue.
export function accentForeground(color: string): ResourceColor {
  const luminance = accentLuminance(parseInt(color.slice(1), 16));
  return 1.05 / (luminance + 0.05) >= 3 ? Color.White : Color.Black;
}

export function updateAccentInk(dark: boolean): void {
  AppStorage.setOrCreate('qyxAccentDark', dark);
  const color = AppStorage.get<string>('qyxAccent') || DEFAULT_ACCENT;
  const rgb = parseInt(color.slice(1), 16);
  let adjusted = rgb;
  const target = dark ? 255 : 0;
  for (let step = 1; step <= 20; step++) {
    const brightness = accentLuminance(adjusted);
    if (dark ? brightness >= 0.18 : brightness <= 0.183) break;
    const ratio = step / 20;
    const red = Math.round(((rgb >> 16) & 255) * (1 - ratio) + target * ratio);
    const green = Math.round(((rgb >> 8) & 255) * (1 - ratio) + target * ratio);
    const blue = Math.round((rgb & 255) * (1 - ratio) + target * ratio);
    adjusted = (red << 16) | (green << 8) | blue;
  }
  AppStorage.setOrCreate('qyxAccentInk', '#' + adjusted.toString(16).padStart(6, '0'));
}

export function initializeAppearancePreferences(context: common.UIAbilityContext): void {
  let index = DEFAULT_TAB_MATERIAL;
  let height = DEFAULT_TAB_HEIGHT;
  let showLabels = false;
  let gripAware = false;
  let accent = DEFAULT_ACCENT;
  try {
    const store = preferences.getPreferencesSync(context, { name: STORE });
    const value = store.getSync('tabMaterial', index);
    if (typeof value === 'number' && TAB_MATERIAL_STYLES[value] !== undefined) index = value;
    const savedHeight = store.getSync('tabHeight', height);
    if (typeof savedHeight === 'number' && TAB_HEIGHTS.includes(savedHeight)) height = savedHeight;
    showLabels = store.getSync('tabLabels', false) === true;
    gripAware = store.getSync('composeGripAware', false) === true;
    const savedAccent = store.getSync('accent', accent);
    if (typeof savedAccent === 'string' && validAccent(savedAccent)) accent = savedAccent;
  } catch (_) {}
  AppStorage.setOrCreate('qyxTabMaterial', index);
  AppStorage.setOrCreate('qyxTabHeight', height);
  AppStorage.setOrCreate('qyxTabLabels', showLabels);
  AppStorage.setOrCreate('qyxComposeGripAware', gripAware);
  AppStorage.setOrCreate('qyxAccent', accent);
  updateAccentInk(AppStorage.get<boolean>('qyxAccentDark') === true);
}

export async function saveComposeGrip(context: common.UIAbilityContext, enabled: boolean): Promise<void> {
  const store = await preferences.getPreferences(context, { name: STORE });
  await store.put('composeGripAware', enabled);
  await store.flush();
  AppStorage.setOrCreate('qyxComposeGripAware', enabled);
}

export async function saveAccent(context: common.UIAbilityContext, color: string): Promise<void> {
  if (!validAccent(color)) return;
  const store = await preferences.getPreferences(context, { name: STORE });
  await store.put('accent', color);
  await store.flush();
  AppStorage.setOrCreate('qyxAccent', color);
  updateAccentInk(AppStorage.get<boolean>('qyxAccentDark') === true);
}

export async function saveTabLayout(context: common.UIAbilityContext, height: number, showLabels: boolean): Promise<void> {
  if (!TAB_HEIGHTS.includes(height)) return;
  const store = await preferences.getPreferences(context, { name: STORE });
  await store.put('tabHeight', height);
  await store.put('tabLabels', showLabels);
  await store.flush();
  AppStorage.setOrCreate('qyxTabHeight', height);
  AppStorage.setOrCreate('qyxTabLabels', showLabels);
}

export async function saveTabMaterial(context: common.UIAbilityContext, index: number): Promise<void> {
  if (TAB_MATERIAL_STYLES[index] === undefined) return;
  const store = await preferences.getPreferences(context, { name: STORE });
  await store.put('tabMaterial', index);
  await store.flush();
  AppStorage.setOrCreate('qyxTabMaterial', index);
}
