#ifndef RAY_CORE_AC_CONTENT_HOOKS_H_
#define RAY_CORE_AC_CONTENT_HOOKS_H_

#include <stddef.h>

#include <memory>
#include <string>
#include <string_view>

#include "base/functional/callback_forward.h"
#include "extensions/common/extension_id.h"

class GURL;

namespace content {
class BrowserContext;
class DevToolsAgentHost;
class DevToolsAgentHostClient;
class DevToolsSocketFactory;
class RenderFrameHost;
class WebContents;

extern bool g_ray_opacity_from_default_color;

bool RayHasAccessedInitialMainDocument(WebContents* contents);

bool RayMainFrameHandlesEnterPictureInPicture(WebContents* contents);
}

namespace crypto::apple {
class KeychainV2;
}

class SessionID;

namespace sessions {
class LiveTab;
}

namespace extensions {
struct WebRequestInfo;
namespace declarative_net_request {
struct RequestAction;
}
}

extern int g_ray_disk_space_check_seconds;

extern bool g_ray_auto_picture_in_picture_off;

extern bool (*g_ray_safe_storage_key_may_be_created)();

extern void (*g_ray_safe_storage_unreadable)(int status,
                                              base::OnceClosure retry);

extern crypto::apple::KeychainV2* (*g_ray_test_keychain)();

extern bool g_ray_lazy_storage_usage;

extern bool g_ray_script_loader_ready_at_once;

extern bool g_ray_scripts_wait_at_response;

extern bool g_ray_bluetooth_poll_on_demand;

extern bool g_ray_hybrid_scan_on_demand;

void RaySetHybridUiShown(const void* model, bool shown);

extern bool (*g_ray_restricted_component_extension)(
    const extensions::ExtensionId& extension_id);

extern bool g_ray_begin_frame_bridge;

extern void (*g_ray_initial_main_document_accessed)(
    content::WebContents* contents);

extern bool (*g_ray_live_tab_skips_restore)(sessions::LiveTab* live_tab,
                                              SessionID* source);

extern int (*g_ray_permission_tab_shown)(content::WebContents*);

extern void (*g_ray_dnr_rule_matched)(
    content::BrowserContext* browser_context,
    int tab_id,
    const extensions::declarative_net_request::RequestAction& action,
    const extensions::WebRequestInfo& request);

extern void (*g_ray_dnr_rulesets_in_force)(
    content::BrowserContext* browser_context,
    const extensions::ExtensionId& extension_id,
    bool all_loaded);

extern bool (*g_ray_devtools_token_factory)(
    const content::DevToolsSocketFactory* factory);

extern bool (*g_ray_devtools_token_accepts)(
    const content::DevToolsSocketFactory* factory,
    std::string_view token);

extern void (*g_ray_devtools_token_server)(
    const content::DevToolsSocketFactory* factory,
    std::string_view browser_path,
    int port,
    size_t connections);

extern bool (*g_ray_devtools_active_target)(
    const content::DevToolsSocketFactory* factory,
    std::string_view token,
    std::string* target_id);

class RayDevToolsTokenClient {
 public:
  virtual ~RayDevToolsTokenClient() = default;
  virtual bool FilterCommand(std::string& message, std::string* reply) = 0;
  virtual bool FilterEvent(std::string& message) = 0;
  virtual bool ShouldClose() const = 0;
  virtual bool MayAttachToURL(const GURL& url, bool is_webui) = 0;
  virtual bool MayAttachToRenderFrameHost(
      content::RenderFrameHost* render_frame_host) = 0;
};

extern std::unique_ptr<RayDevToolsTokenClient> (*g_ray_devtools_token_client)(
    const content::DevToolsSocketFactory* factory,
    content::DevToolsAgentHostClient* client,
    content::DevToolsAgentHost* host);

extern bool (*g_ray_devtools_may_attach)(
    content::DevToolsAgentHostClient* root_client,
    content::DevToolsAgentHost* host);

extern bool (*g_ray_devtools_may_input)(
    content::DevToolsAgentHostClient* root_client,
    content::RenderFrameHost* frame);

#endif
