#ifndef V2X_GOSSIP_APP_H
#define V2X_GOSSIP_APP_H

#include "ns3/application.h"
#include "ns3/socket.h"
#include <functional>
#include <string>

namespace ns3 {

class V2xGossipApp : public Application
{
public:
  static TypeId GetTypeId();

  V2xGossipApp();
  virtual ~V2xGossipApp();

  void Send(const uint8_t* data, uint32_t len);
  void StopApplicationNow();

  using RxCallback = std::function<void(const std::string& vehicleId,
                                        const uint8_t* data, uint32_t len)>;
  void SetReceiveCallback(RxCallback cb);

private:
  void StartApplication() override;
  void StopApplication() override;
  void Receive(Ptr<Socket> socket);

  Ptr<Socket>  m_socket;
  std::string  m_vehicleId;
  uint16_t     m_port = 8001;
  RxCallback   m_rxCallback;
};

} // namespace ns3

#endif /* V2X_GOSSIP_APP_H */
