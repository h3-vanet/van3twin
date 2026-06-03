#include "v2x-gossip-app-helper.h"

#include "ns3/v2x-gossip-app.h"
#include "ns3/names.h"

namespace ns3 {

V2xGossipAppHelper::V2xGossipAppHelper()
{
  m_factory.SetTypeId(V2xGossipApp::GetTypeId());
}

void
V2xGossipAppHelper::SetAttribute(std::string name, const AttributeValue& value)
{
  m_factory.Set(name, value);
}

ApplicationContainer
V2xGossipAppHelper::Install(Ptr<Node> node) const
{
  return ApplicationContainer(InstallPriv(node));
}

ApplicationContainer
V2xGossipAppHelper::Install(std::string nodeName) const
{
  Ptr<Node> node = Names::Find<Node>(nodeName);
  return ApplicationContainer(InstallPriv(node));
}

ApplicationContainer
V2xGossipAppHelper::Install(NodeContainer c) const
{
  ApplicationContainer apps;
  for (auto it = c.Begin(); it != c.End(); ++it)
    apps.Add(InstallPriv(*it));
  return apps;
}

Ptr<Application>
V2xGossipAppHelper::InstallPriv(Ptr<Node> node) const
{
  Ptr<Application> app = m_factory.Create<V2xGossipApp>();
  node->AddApplication(app);
  return app;
}

} // namespace ns3
