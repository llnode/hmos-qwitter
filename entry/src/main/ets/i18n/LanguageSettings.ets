import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { i18n } from '@kit.LocalizationKit';
import { resolveAppLocale, validLanguageChoice } from './LocalePolicy';

const STORE: string = 'qyx-language';
let languages: Record<string, Record<string, string>> = {};

export function ui(text: string, locale: string, value: string = ''): string {
  return (languages[locale]?.[text] || text).replace('{0}', value);
}

function deviceLocale(): string {
  try {
    return resolveAppLocale(i18n.System.getSystemLanguage());
  } catch (_) {
    return 'zh-Hans';
  }
}

function applyUiLanguage(context: common.UIAbilityContext, language: string): void {
  const locale = language === 'system' ? deviceLocale() : language;
  if (AppStorage.get<string>('qyxLocale') === locale &&
    AppStorage.get<string>('qyxAppLanguage') === language) return;
  AppStorage.setOrCreate('qyxAppLanguage', language);
  AppStorage.setOrCreate('qyxLocale', locale);
  try {
    context.getApplicationContext().setLanguage(locale);
  } catch (_) {
    // The app's own strings still follow the selected language.
  }
}

export function initializeLanguages(context: common.UIAbilityContext): void {
  let language = 'system';
  let target = '';
  try {
    const raw = context.resourceManager.getRawFileContentSync('ui-languages.json');
    languages = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(raw)) as Record<string, Record<string, string>>;
    const store = preferences.getPreferencesSync(context, { name: STORE });
    const savedLanguage = store.getSync('app', 'system');
    const savedTarget = store.getSync('post', '');
    if (typeof savedLanguage === 'string' && validLanguageChoice(savedLanguage)) language = savedLanguage;
    if (typeof savedTarget === 'string' && savedTarget !== 'system' && validLanguageChoice(savedTarget)) {
      target = savedTarget;
    }
  } catch (_) {}
  applyUiLanguage(context, language);
  AppStorage.setOrCreate('qyxTranslationLanguage', target);
}

export function followDeviceLanguage(context: common.UIAbilityContext): void {
  if (AppStorage.get<string>('qyxAppLanguage') === 'system') applyUiLanguage(context, 'system');
}

export async function saveLanguage(context: common.UIAbilityContext, forPosts: boolean, value: string): Promise<void> {
  if (forPosts ? (value !== '' && (value === 'system' || !validLanguageChoice(value))) : !validLanguageChoice(value)) {
    return;
  }
  const store = await preferences.getPreferences(context, { name: STORE });
  await store.put(forPosts ? 'post' : 'app', value);
  await store.flush();
  if (forPosts) AppStorage.setOrCreate('qyxTranslationLanguage', value);
  else applyUiLanguage(context, value);
}

export function xLanguage(locale: string): string {
  if (locale === 'zh-Hans') return 'zh-CN';
  if (locale === 'zh-Hant') return 'zh-TW';
  if (locale === 'fil-PH') return 'fil';
  return locale;
}
