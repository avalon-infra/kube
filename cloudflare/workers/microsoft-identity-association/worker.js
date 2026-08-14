const VERIFICATIONS = {
  "calendar.matiix310.dev": {
    associatedApplications: [
      { applicationId: "8a6b6e78-4265-4ace-86cd-3707e8ef812f" }
    ]
  }
  // Add more subdomains here as you need them, e.g.:
  // "api.matiix310.dev": { associatedApplications: [{ applicationId: "..." }] }
};

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const data = VERIFICATIONS[url.hostname];

    if (!data) {
      return new Response("Not found", { status: 404 });
    }

    return new Response(JSON.stringify(data, null, 2), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  },
};
