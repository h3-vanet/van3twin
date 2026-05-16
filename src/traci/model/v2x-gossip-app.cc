#include "v2x-gossip-app.h"

#include "ns3/log.h"
#include "ns3/udp-socket-factory.h"
#include "ns3/inet-socket-address.h"
#include "ns3/packet.h"
#include "ns3/string.h"
#include "ns3/uinteger.h"

namespace ns3 {

NS_LOG_COMPONENT_DEFINE("V2xGossipApp");
NS_OBJECT_ENSURE_REGISTERED(V2xGossipApp);

TypeId
V2xGossipApp::GetTypeId()
{
  static TypeId tid =
      TypeId("ns3::V2xGossipApp")
      .SetParent<Application>()
      .SetGroupName("Applications")
      .AddConstructor<V2xGossipApp>()
      .AddAttribute("VehicleId",
                    "SUMO vehicle identifier",
                    StringValue(""),
                    MakeStringAccessor(&V2xGossipApp::m_vehicleId),
                    MakeStringChecker())
      .AddAttribute("Port",
                    "UDP port for gossip traffic",
                    UintegerValue(8001),
                    MakeUintegerAccessor(&V2xGossipApp::m_port),
                    MakeUintegerChecker<uint16_t>());
  return tid;
}

V2xGossipApp::V2xGossipApp() = default;
V2xGossipApp::~V2xGossipApp() = default;

void
V2xGossipApp::SetReceiveCallback(RxCallback cb)
{
  m_rxCallback = std::move(cb);
}

void
V2xGossipApp::StartApplication()
{
  m_socket = Socket::CreateSocket(GetNode(), UdpSocketFactory::GetTypeId());
  m_socket->SetAllowBroadcast(true);

  InetSocketAddress local = InetSocketAddress(Ipv4Address::GetAny(), m_port);
  m_socket->Bind(local);

  m_socket->SetRecvCallback(MakeCallback(&V2xGossipApp::Receive, this));
}

void
V2xGossipApp::StopApplication()
{
  if (m_socket)
    {
      m_socket->Close();
      m_socket->SetRecvCallback(MakeNullCallback<void, Ptr<Socket>>());
      m_socket = nullptr;
    }
}

void
V2xGossipApp::Send(const uint8_t* data, uint32_t len)
{
  if (!m_socket) return;
  Ptr<Packet> pkt = Create<Packet>(data, len);
  InetSocketAddress dest(Ipv4Address("225.0.0.0"), m_port);
  m_socket->SendTo(pkt, 0, dest);
}

void
V2xGossipApp::Receive(Ptr<Socket> socket)
{
  Ptr<Packet> pkt;
  Address from;
  while ((pkt = socket->RecvFrom(from)) != nullptr)
    {
      uint32_t size = pkt->GetSize();
      uint8_t* buf  = new uint8_t[size];
      pkt->CopyData(buf, size);
      if (m_rxCallback)
        m_rxCallback(m_vehicleId, buf, size);
      delete[] buf;
    }
}

} // namespace ns3
