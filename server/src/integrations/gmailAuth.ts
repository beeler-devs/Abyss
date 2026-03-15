export interface GoogleTokenResponse {
  access_token: string;
  refresh_token?: string;
  expires_in: number;
  token_type: string;
}

export async function exchangeGoogleCode(
  code: string,
  clientId: string,
  clientSecret: string,
  redirectUri: string,
): Promise<GoogleTokenResponse> {
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      code,
      client_id: clientId,
      client_secret: clientSecret,
      redirect_uri: redirectUri,
      grant_type: "authorization_code",
    }),
    signal: AbortSignal.timeout(10_000),
  });

  const payload = (await response.json()) as Record<string, unknown>;

  if (typeof payload.error === "string") {
    throw new Error(`google_token_error:${payload.error}`);
  }

  const accessToken = payload.access_token;
  if (typeof accessToken !== "string" || !accessToken) {
    throw new Error("google_missing_access_token");
  }

  return {
    access_token: accessToken,
    refresh_token: typeof payload.refresh_token === "string" ? payload.refresh_token : undefined,
    expires_in: typeof payload.expires_in === "number" ? payload.expires_in : 3600,
    token_type: typeof payload.token_type === "string" ? payload.token_type : "Bearer",
  };
}

export async function refreshGoogleToken(
  refreshToken: string,
  clientId: string,
  clientSecret: string,
): Promise<{ access_token: string; expires_in: number }> {
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      refresh_token: refreshToken,
      client_id: clientId,
      client_secret: clientSecret,
      grant_type: "refresh_token",
    }),
    signal: AbortSignal.timeout(10_000),
  });

  const payload = (await response.json()) as Record<string, unknown>;

  if (typeof payload.error === "string") {
    throw new Error(`google_refresh_error:${payload.error}`);
  }

  const accessToken = payload.access_token;
  if (typeof accessToken !== "string" || !accessToken) {
    throw new Error("google_refresh_missing_access_token");
  }

  return {
    access_token: accessToken,
    expires_in: typeof payload.expires_in === "number" ? payload.expires_in : 3600,
  };
}
