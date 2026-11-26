export class LegalSection {
  readonly title: string;
  readonly body: string;

  constructor(title: string, body: string) {
    this.title = title;
    this.body = body;
  }
}

export function legalSections(privacy: boolean, locale: string): LegalSection[] {
  if (locale.startsWith('zh')) {
    return privacy ? [
      new LegalSection('Qwitter 如何处理信息', 'Qwitter 不运营用于关联用户身份的服务器，不向 Qwitter 运营方上传用户信息、使用记录或分析数据，也不使用这些信息进行广告跟踪。'),
      new LegalSection('本机数据', '为了显示时间线、资料、通知和聊天，应用把相关内容和缓存保存在设备上的本地数据库，供应用读取。应用偏好保存在本机，X 登录会话由系统网页组件在本机保存。开启智感握姿时，应用使用系统提供的握持方向或最近的操作手调整发帖按钮位置。'),
      new LegalSection('与 X 和外部网站通信', '登录和使用 X 功能时，设备会直接连接 X 及其内容服务。发帖、聊天和互动等操作会提交给 X。X 如何处理这些信息由其隐私政策（x.com/privacy）说明。打开外部链接时，目标网站适用自己的隐私政策。'),
      new LegalSection('管理本机数据', '在设置中退出登录会清除本机的 X 会话和账号缓存。你也可以通过系统设置清除应用数据。已保存到相册的文件由你在相册中管理，X 账号上的内容由你在 X 中管理。')
    ] : [
      new LegalSection('适用范围', 'Qwitter 是独立的 X 客户端。使用 Qwitter 时，请遵守本条款和适用法律。你的 X 账号、内容和平台操作还适用 X 的服务条款（x.com/tos）及平台规则。'),
      new LegalSection('账号和内容', '请仅使用你有权访问的账号，并对通过该账号发布或发送的内容负责。下载、保存或分享他人内容时，请尊重权利人的权利以及他人的隐私。'),
      new LegalSection('服务可用性', 'Qwitter 的部分功能依赖 X、网络和设备系统。X 的页面、功能和访问规则发生变化时，部分功能可能暂时不可用。'),
      new LegalSection('停止使用和条款更新', '你可以随时退出登录或卸载应用。更新后的条款可在应用内查看。本条款不影响适用法律赋予你的权利。')
    ];
  }
  return privacy ? [
    new LegalSection('How Qwitter handles information', 'Qwitter operates no server that associates data with your identity. It does not upload personal information, usage records or analytics to the Qwitter operator, or use that information for advertising tracking.'),
    new LegalSection('Data on your device', 'Qwitter keeps account content and caches in a local database to display timelines, profiles, notifications and chats. Preferences stay on your device. The system web component stores your X session locally. Optional grip detection uses the system’s holding direction or most recent operating hand to place the compose button.'),
    new LegalSection('X and external websites', 'Your device connects directly to X and its content services. Posts, messages and interactions are submitted to X. See the X Privacy Policy (x.com/privacy) for how X handles this information. External sites apply their own privacy policies.'),
    new LegalSection('Manage local data', 'Signing out clears the local X session and account cache. You can also clear app data in device settings. Manage saved media in your photo library and X account content on X.')
  ] : [
    new LegalSection('Scope', 'Qwitter is an independent X client. Please follow these terms and applicable law. Your X account, content and platform activity are also subject to the X Terms of Service (x.com/tos) and platform rules.'),
    new LegalSection('Accounts and content', 'Use only accounts you are authorized to access. You are responsible for content you publish or send. Respect others’ rights and privacy when downloading, saving or sharing content.'),
    new LegalSection('Availability', 'Some features depend on X, your network and your device. Changes to X pages, features or access rules can make features temporarily unavailable.'),
    new LegalSection('Stopping use and updates', 'You can sign out or uninstall Qwitter at any time. Updated terms are available in the app. These terms do not affect your rights under applicable law.')
  ];
}
