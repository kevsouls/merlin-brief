async () => {
  const r = await cloudflare.request({
    method: "GET",
    path: "/accounts/" + accountId + "/pages/projects/merlin-brief/upload-token",
  });
  return r.success ? { jwt: r.result.jwt } : { errors: r.errors };
}
