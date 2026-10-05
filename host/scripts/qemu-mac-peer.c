/* Disposable, read-only protocol probe. Never connects to the running viewer. */
#include <rfb/rfbclient.h>
#include <openssl/provider.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int completed;

static char *password(rfbClient *client) {
    (void)client;
    return strdup("sdvmtest"); /* Public fixture credential, not a real password. */
}

static void updated(rfbClient *client) {
    (void)client;
    completed = 1;
}

int main(int argc, char **argv) {
    if (argc != 2) return 64;
    char *end;
    long port = strtol(argv[1], &end, 10);
    if (!*argv[1] || *end || port < 1 || port > 65535) return 64;
    alarm(20); /* Bound even a blocked library call; this is a separate process. */
    OSSL_PROVIDER *normal = OSSL_PROVIDER_load(NULL, "default");
    OSSL_PROVIDER *legacy = OSSL_PROVIDER_load(NULL, "legacy");
    if (!normal || !legacy) return 2;
    rfbClient *client = rfbGetClient(8, 3, 4);
    if (!client) return 2;
    client->serverHost = strdup("127.0.0.1");
    client->serverPort = (int)port;
    client->GetPassword = password;
    client->FinishedFrameBufferUpdate = updated;
    client->appData.encodingsString = "zrle raw";
    client->appData.enableJPEG = FALSE;
    client->connectTimeout = 3;
    client->readTimeout = 0;
    int count = 1;
    char *arguments[] = {"sharedesk-isolated-mac-peer", NULL};
    if (!rfbInitClient(client, &count, arguments)) return 3;
    while (!completed) {
        int ready = client->buffered ? 1 : WaitForMessage(client, 10000);
        if (ready < 0 || (ready > 0 && !HandleRFBServerMessage(client))) break;
    }
    printf("Mac LibVNCClient: framebuffer=%dx%d completed=%d\n",
           client->width, client->height, completed);
    int success = completed && client->width == 1280 && client->height == 800;
    free(client->frameBuffer);
    client->frameBuffer = NULL;
    rfbClientCleanup(client);
    OSSL_PROVIDER_unload(legacy);
    OSSL_PROVIDER_unload(normal);
    return success ? 0 : 4;
}
