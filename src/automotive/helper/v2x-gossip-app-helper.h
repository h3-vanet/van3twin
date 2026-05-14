#ifndef V2X_GOSSIP_APP_HELPER_H
#define V2X_GOSSIP_APP_HELPER_H

#include "ns3/application-container.h"
#include "ns3/node-container.h"
#include "ns3/object-factory.h"

namespace ns3 {

class V2xGossipAppHelper
{
public:
  V2xGossipAppHelper();

  void SetAttribute(std::string name, const AttributeValue& value);

  ApplicationContainer Install(Ptr<Node> node) const;
  ApplicationContainer Install(std::string nodeName) const;
  ApplicationContainer Install(NodeContainer c) const;

private:
  Ptr<Application> InstallPriv(Ptr<Node> node) const;
  ObjectFactory m_factory;
};

} // namespace ns3

#endif /* V2X_GOSSIP_APP_HELPER_H */
