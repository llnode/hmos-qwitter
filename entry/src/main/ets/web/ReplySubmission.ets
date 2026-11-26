export class ReplySubmissionResult {
  stage: string = '';
  mayHaveSubmitted: boolean = false;
}

export async function submitWebReply(run: (step: string) => Promise<string>,
  canSend: () => boolean, isActive: () => boolean, wait: (ms: number) => Promise<void>,
  setSubmitting: (submitting: boolean) => void, timeout: number): Promise<ReplySubmissionResult> {
  const result = new ReplySubmissionResult();
  const deadline = Date.now() + timeout;
  while (canSend() && Date.now() < deadline) {
    try {
      result.stage = await run('prepare');
      if (!canSend() || result.stage === 'attachment-failed') return result;
      if (result.stage === 'prepared' || result.stage === 'submitted') {
        setSubmitting(true);
        result.mayHaveSubmitted = true;
        if (result.stage !== 'submitted') result.stage = await run('submit');
        if (result.stage === 'submitted') break;
        result.mayHaveSubmitted = false;
        setSubmitting(false);
      }
    } catch (_) {
      if (result.mayHaveSubmitted) return result;
      result.stage = 'reply-bridge-unavailable';
    }
    await wait(250);
  }
  if (!result.mayHaveSubmitted) return result;
  const verifyUntil = Date.now() + 8000;
  while (isActive() && Date.now() < verifyUntil) {
    try {
      result.stage = await run('verify');
      if (/^confirmed:\d{1,24}$/.test(result.stage)) break;
    } catch (_) {}
    await wait(350);
  }
  return result;
}
