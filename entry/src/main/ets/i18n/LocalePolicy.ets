export class AppLanguage {
  tag: string;
  name: string;
  country: string;
  constructor(tag: string, name: string, country: string = '') { this.tag = tag; this.name = name; this.country = country; }
}
export const APP_LANGUAGES: AppLanguage[] = [
  new AppLanguage('system', '自动（跟随设备语言）'),
  new AppLanguage('zh-Hans', '简体中文（中国）', 'cn'), new AppLanguage('zh-Hant', '繁體中文（港澳臺）', 'cn'),
  new AppLanguage('en-US', 'English (US)', 'us'), new AppLanguage('en-GB', 'English (UK)', 'gb'),
  new AppLanguage('fr-FR', 'Français', 'fr'), new AppLanguage('de-DE', 'Deutsch', 'de'),
  new AppLanguage('ja-JP', '日本語', 'jp'), new AppLanguage('ko-KR', '한국어', 'kr'),
  new AppLanguage('it-IT', 'Italiano', 'it'), new AppLanguage('nl-NL', 'Nederlands', 'nl'),
  new AppLanguage('es-ES', 'Español', 'es'), new AppLanguage('pt-PT', 'Português', 'pt'),
  new AppLanguage('ar', 'العربية', 'sa'), new AppLanguage('es-419', 'Español (Latinoamérica)', 'mx'),
  new AppLanguage('id-ID', 'Bahasa Indonesia', 'id'), new AppLanguage('pt-BR', 'Português (Brasil)', 'br'),
  new AppLanguage('vi-VN', 'Tiếng Việt', 'vn'), new AppLanguage('th-TH', 'ไทย', 'th'),
  new AppLanguage('ms-MY', 'Bahasa Melayu', 'my'), new AppLanguage('fil-PH', 'Filipino', 'ph'),
  new AppLanguage('sw', 'Kiswahili', 'ke'),
  new AppLanguage('ru-RU', 'Русский', 'ru'), new AppLanguage('pl-PL', 'Polski', 'pl')
];
export function resolveAppLocale(language: string): string {
  const parts = language.trim().replace(/_/g, '-').toLowerCase().split('-');
  const base = parts[0];
  if (base === 'zh') { return parts.includes('hant') || (!parts.includes('hans') && parts.some((part: string) => ['tw','hk','mo'].includes(part))) ? 'zh-Hant' : 'zh-Hans'; }
  if (base === 'en') { return parts.includes('gb') ? 'en-GB' : 'en-US'; }
  if (base === 'es') { return parts.some((part: string) => ['419','mx','ar','bo','cl','co','cr','cu','do','ec','sv','gt','hn','ni','pa','py','pe','pr','uy','ve','us','bz'].includes(part)) ? 'es-419' : 'es-ES'; }
  if (base === 'pt') { return parts.includes('br') ? 'pt-BR' : 'pt-PT'; }
  if (base === 'ar') { return 'ar'; }
  if (base === 'sw') { return 'sw'; }
  if (base === 'fil' || base === 'tl') { return 'fil-PH'; }
  if (base === 'in') { return 'id-ID'; }
  const bases = ['fr','de','ja','ko','it','nl','es','pt','ru','pl','id','vi','th','ms'];
  const targets = ['fr-FR','de-DE','ja-JP','ko-KR','it-IT','nl-NL','es-ES','pt-PT','ru-RU','pl-PL','id-ID','vi-VN','th-TH','ms-MY'];
  const index = bases.indexOf(base); return index >= 0 ? targets[index] : 'en-US';
}
export function validLanguageChoice(value: string): boolean { return APP_LANGUAGES.some((item: AppLanguage) => item.tag === value); }
export function languageName(value: string): string { return APP_LANGUAGES.find((item: AppLanguage) => item.tag === value)?.name || APP_LANGUAGES[0].name; }

export function isRtlLocale(locale: string): boolean { return resolveAppLocale(locale) === 'ar'; }
