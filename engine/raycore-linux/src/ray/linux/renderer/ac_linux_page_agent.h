#ifndef RAY_LINUX_RENDERER_AC_LINUX_PAGE_AGENT_H_
#define RAY_LINUX_RENDERER_AC_LINUX_PAGE_AGENT_H_

namespace content {
class RenderFrame;
}

namespace ray {

void CreateLinuxPageAgent(content::RenderFrame* frame);
void RunLinuxPageAgentAtDocumentStart(content::RenderFrame* frame);

}

#endif
