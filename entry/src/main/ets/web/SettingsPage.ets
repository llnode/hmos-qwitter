import { X_ORIGIN } from './XPage';

export const SETTINGS_ROOT: string = X_ORIGIN + '/settings';
export const SETTINGS_TITLE: string = 'Qwitter 设置';

export class SettingOption {
  label: string = '';
  value: string = '';
  disabled: boolean = false;
}

export class SettingRow {
  key: string = '';
  kind: string = '';
  label: string = '';
  detail: string = '';
  path: string = '';
  value: string = '';
  checked: boolean = false;
  disabled: boolean = false;
  group: string = '';
  options: SettingOption[] = [];
  min: number = 0;
  max: number = 100;
  step: number = 1;
  inputType: string = '';
  deferred: boolean = false;
}

export class SettingsPage {
  route: string = '';
  cachedAt: number = 0;
  title: string = '';
  rows: SettingRow[] = [];
  dialog: boolean = false;
  signedOut: boolean = false;
  applied: boolean = false;
  documentId: string = '';
  notice: string = '';
  error: string = '';
  busy: boolean = false;
}

export class SettingEdit {
  key: string;
  kind: string;
  label: string;
  value: string;

  constructor(row: SettingRow, value: string) {
    this.key = row.key;
    this.kind = row.kind;
    this.label = row.label;
    this.value = value;
  }
}

export class SettingAction extends SettingEdit {
  route: string;
  checked: boolean;
  submit: boolean;
  fields: SettingEdit[];

  constructor(route: string, row: SettingRow, value: string, checked: boolean, submit: boolean, fields: SettingEdit[]) {
    super(row, value);
    this.route = route;
    this.checked = checked;
    this.submit = submit;
    this.fields = fields;
  }
}

export function settingsRoute(value: string): string {
  const url = (value.startsWith('/') ? X_ORIGIN + value : value).split('#')[0];
  if (!/^https:\/\/(?:x\.com\/(?:settings(?:\/|\?|$)|i\/(?:premium|verified(?:_orgs)?|flow)(?:\/|\?|$)|(?:[a-z-]+\/)?(?:privacy|tos)(?:\/|\?|$))|(?:help|privacy|legal)\.x\.com(?:\/|\?|$))[^\s]*$/i.test(url)) return '';
  return url.replace(/\/(?=\?|$)/, '');

}

export function readSettingsSnapshot(raw: string): SettingsPage | null {
  if (!raw || raw.length > 450000) return null;
  try {
    const json = raw.startsWith('"') ? JSON.parse(raw) as string : raw;
    const snapshot = JSON.parse(json) as SettingsPage;
    if (!snapshot || typeof snapshot.route !== 'string' || !Array.isArray(snapshot.rows)) return null;
    snapshot.rows = snapshot.rows.filter((row: SettingRow) => row &&
      typeof row.label === 'string' && row.label.length > 0 &&
      (row.kind !== 'link' || !!settingsRoute(row.path)));
    return snapshot;
  } catch (_) {
    return null;
  }
}
