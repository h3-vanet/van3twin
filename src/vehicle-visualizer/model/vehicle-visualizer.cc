/* -*- Mode:C++; c-file-style:"gnu"; indent-tabs-mode:nil; -*- */

#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/udp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <sstream>
#include <cstdio>
#include "vehicle-visualizer.h"

namespace ns3 {
  NS_LOG_COMPONENT_DEFINE("vehicleVisualizer");

  vehicleVisualizer::vehicleVisualizer()
  {
      // Set default ip and port
      m_ip="127.0.0.1";
      m_port=48110;

      // Set the default HTTP Node.js server port
      m_httpport=8080;

      m_is_connected=false;
      m_is_map_sent=false;
      m_is_server_active=false;
      m_serverpath=DEFAULT_NODEJS_SERVER_PATH;
  }

  vehicleVisualizer::vehicleVisualizer(int port)
  {
      // Set default ip
      m_ip="127.0.0.1";
      m_port=port;

      // Set the default HTTP Node.js server port
      m_httpport=8080;

      m_is_connected=false;
      m_is_map_sent=false;
      m_is_server_active=false;
      m_serverpath=DEFAULT_NODEJS_SERVER_PATH;
  }

  vehicleVisualizer::vehicleVisualizer(int port,std::string ipv4)
  {
      m_ip=ipv4;
      m_port=port;

      m_httpport=8080;

      m_is_connected=false;
      m_is_map_sent=false;
      m_is_server_active=false;
      m_serverpath=DEFAULT_NODEJS_SERVER_PATH;
  }

  int
  vehicleVisualizer::connectToServer()
  {
      m_sockfd=socketOpen();

      if(m_sockfd<0)
      {
          return -1;
      }

      m_is_connected=true;

      return 0;
  }

  vehicleVisualizer::~vehicleVisualizer()
  {
      // The destructor will attempt to send a termination message to the Node.js server only if a server
      // was successfully started with startServer()
      if(m_is_server_active)
      {
        terminateServer ();
        // Close the UDP socket, if it was opened before
        if(m_sockfd!=-1)
        {
          close(m_sockfd);
          m_sockfd=-1;
        }
       }
  }

  int
  vehicleVisualizer::sendMapDraw(double lat, double lon)
  {
      if(m_is_connected==false)
      {
          NS_FATAL_ERROR("Error: attempted to use a non-connected vehicle visualizer client.");
      }

      if(m_is_map_sent==true)
      {
          NS_FATAL_ERROR("Error in vehicle visualizer client: attempted to send twice a map draw message. This is not allowed.");
      }

      std::ostringstream oss;
      int send_rval=-1;

      oss.precision(7);
      oss<<"map,"<<lat<<","<<lon;

      std::string msg_string = oss.str();
      char *msg_buffer = new char[msg_string.length() + 1];
      std::copy(msg_string.c_str(), msg_string.c_str() + msg_string.length() + 1, msg_buffer);

      send_rval=send(m_sockfd,msg_buffer,msg_string.length()+1,0);

      delete[] msg_buffer;

      m_is_map_sent=true;

      return send_rval;
  }

  int
  vehicleVisualizer::sendObjectUpdate(std::string objID, double lat, double lon, double heading)
  {
      if(m_is_connected==false)
      {
          NS_FATAL_ERROR("Error: attempted to use a non-connected vehicle visualizer client.");
      }

      if(m_is_map_sent==false)
      {
          NS_FATAL_ERROR("Error in vehicle visualizer client: attempted to send an object update before sending the map draw message.");
      }

      std::ostringstream oss;
      int send_rval=-1;

      oss.precision(7);
      oss<<"object,"<<objID<<","<<lat<<","<<lon<<",";
      oss.precision(3);
      oss<<heading;

      std::string msg_string = oss.str();
      char *msg_buffer = new char[msg_string.length()+1];
      std::copy(msg_string.c_str(), msg_string.c_str() + msg_string.length() + 1, msg_buffer);

      send_rval=send(m_sockfd,msg_buffer,msg_string.length()+1,0);

      delete[] msg_buffer;

      return send_rval;
  }

  int
  vehicleVisualizer::sendObjectUpdate(std::string objID, double lat, double lon)
  {
      return sendObjectUpdate (objID,lat,lon,VIS_HEADING_INVALID);
  }

  int
  vehicleVisualizer::startServer()
  {
      std::string servercmd;

      int nodeCheckRval = std::system("command -v node > /dev/null");

      if(nodeCheckRval != 0)
      {
        NS_FATAL_ERROR("Error. Node.js does not seem to be installed. Please install it before using the ms-van3t vehicle visualizer.");
      }

      servercmd = "node " + m_serverpath + " " + std::to_string(m_httpport) + " &";
      int startCmdRval = std::system(servercmd.c_str());

      // If the result is 0, system() was able to successfully launch the command (which may fail afterwards, though)
      if (startCmdRval == 0)
      {
        NS_LOG_INFO("Used the following command to start up the vehicle visualizer Node.js server: " << servercmd);
        m_is_server_active = true;
      }
      else
      {
        NS_FATAL_ERROR("Cannot send the command for starting the Node.js server.");
      }

      // Wait 1 second for the server to come up
      sleep(1);

      return startCmdRval;
  }

  int
  vehicleVisualizer::terminateServer()
  {
      if(m_is_connected==false)
      {
          NS_FATAL_ERROR("Error: attempted to use a non-connected vehicle visualizer client.");
      }

      // Just send a message with the "terminate" string
      char terminatebuf[10]="terminate";

      int retval = send(m_sockfd,terminatebuf,9,0);
      if (retval==9)
      {
        m_is_connected=false;
        m_is_server_active=false;
      }

      return retval;
  }

  int
  vehicleVisualizer::socketOpen(void)
  {
      struct sockaddr_in saddr={};
      struct in_addr destIPaddr;
      int sockfd;

      sockfd=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);

      if(sockfd<0)
      {
        perror("socket() error:");
        NS_FATAL_ERROR("Error! Cannot open the UDP socket for the vehicle visualizer.");
      }

      // Bind structure
      saddr.sin_family=AF_INET;
      saddr.sin_port=0;
      saddr.sin_addr.s_addr=INADDR_ANY;

      if(bind(sockfd,(struct sockaddr *) &(saddr),sizeof(saddr))<0) {
          perror("Cannot bind socket: bind() error");
          NS_FATAL_ERROR("Error! Cannot bind the UDP socket for the vehicle visualizer.");
      }

      // Get struct in_addr corresponding to the destination IP address
      if(inet_pton(AF_INET,m_ip.c_str(),&(destIPaddr))!=1) {
          fprintf(stderr,"Error in parsing the destination IP address.\n");
          NS_FATAL_ERROR("Error! Cannot parse the destination IP for the UDP socket for the vehicle visualizer.");
      }

      // Connect structure (re-using the same structure - sin_family should remain the same)
      saddr.sin_port=htons(m_port);
      saddr.sin_addr=destIPaddr;

      if(connect(sockfd,(struct sockaddr *) &(saddr),sizeof(saddr))<0) {
          perror("Cannot connect socket: connect() error");
          NS_FATAL_ERROR("Error! Cannot connect the UDP socket for the vehicle visualizer.");
      }

      return sockfd;
  }

  int
  vehicleVisualizer::sendPolygonUpdate(const std::string& polyID,
                                       uint8_t r, uint8_t g, uint8_t b, uint8_t a,
                                       const std::vector<std::pair<double,double>>& coords)
  {
      if (!m_is_connected)
          NS_FATAL_ERROR("Error: attempted to use a non-connected vehicle visualizer client.");
      if (!m_is_map_sent)
          NS_FATAL_ERROR("Error in vehicle visualizer client: sendPolygonUpdate called before sendMapDraw.");
      if (coords.empty())
          return 0;

      // Wire format: poly,<id>,<r>;<g>;<b>;<a>,<lon1>:<lat1>:<lon2>:<lat2>:...
      std::ostringstream oss;
      oss << "poly," << polyID << ","
          << static_cast<int>(r) << ";" << static_cast<int>(g) << ";"
          << static_cast<int>(b) << ";" << static_cast<int>(a) << ",";

      oss.precision(7);
      for (std::size_t i = 0; i < coords.size(); ++i) {
          if (i > 0) oss << ":";
          oss << coords[i].first << ":" << coords[i].second; // lon:lat
      }

      std::string msg = oss.str();
      char* buf = new char[msg.length() + 1];
      std::copy(msg.c_str(), msg.c_str() + msg.length() + 1, buf);
      int ret = send(m_sockfd, buf, msg.length() + 1, 0);
      delete[] buf;
      return ret;
  }

  int
  vehicleVisualizer::sendGossipUpdate(const std::string& vehicleId,
                                      uint32_t txCount, uint32_t rxCount,
                                      uint32_t neighborCount)
  {
      if (!m_is_connected) return -1;

      std::string msg = "gossip," + vehicleId + ","
                      + std::to_string(txCount) + ","
                      + std::to_string(rxCount) + ","
                      + std::to_string(neighborCount);
      char* buf = new char[msg.length() + 1];
      std::copy(msg.c_str(), msg.c_str() + msg.length() + 1, buf);
      int ret = send(m_sockfd, buf, msg.length() + 1, 0);
      delete[] buf;
      return ret;
  }

  int
  vehicleVisualizer::sendExperimentUpdate(const std::string& scenario, uint32_t density,
                                          uint32_t k, uint32_t intervalMs,
                                          uint32_t assignments, uint32_t won,
                                          uint32_t doubleBooking, uint32_t handovers,
                                          double avgSpeedKmh, double simTimeSec)
  {
      if (!m_is_connected) return -1;

      std::ostringstream oss;
      oss.precision(1);
      oss << "experiment," << scenario << ","
          << density << "," << k << "," << intervalMs << ","
          << assignments << "," << won << "," << doubleBooking << ","
          << handovers << "," << std::fixed << avgSpeedKmh << "," << simTimeSec;
      std::string msg = oss.str();
      char* buf = new char[msg.length() + 1];
      std::copy(msg.c_str(), msg.c_str() + msg.length() + 1, buf);
      int ret = send(m_sockfd, buf, msg.length() + 1, 0);
      delete[] buf;
      return ret;
  }

  int
  vehicleVisualizer::sendBatchUpdate(const std::vector<VehiclePosEntry>& vehicles)
  {
      if (!m_is_connected || !m_is_map_sent || vehicles.empty()) return 0;

      std::string msg;
      msg.reserve(vehicles.size() * 80 + 40);
      msg = "{\"type\":\"batch_positions\",\"vehicles\":[";
      char buf[160];
      for (std::size_t i = 0; i < vehicles.size(); ++i) {
          if (i > 0) msg += ',';
          std::snprintf(buf, sizeof(buf),
              "{\"id\":\"%s\",\"lat\":%.7f,\"lng\":%.7f,\"heading\":%.2f}",
              vehicles[i].id.c_str(), vehicles[i].lat, vehicles[i].lng, vehicles[i].heading);
          msg += buf;
      }
      msg += "]}";
      // JSON is self-framing; send without null terminator so JSON.parse succeeds in the browser
      return send(m_sockfd, msg.c_str(), msg.size(), 0);
  }

  std::vector<std::pair<double,double>>
  vehicleVisualizer::parseSumoShape(const std::string& shapeAttr)
  {
      // SUMO shape attribute: "lon,lat lon,lat ..." (space-separated, comma within pair)
      std::vector<std::pair<double,double>> out;
      std::istringstream ss(shapeAttr);
      std::string token;
      while (std::getline(ss, token, ' ')) {
          if (token.empty()) continue;
          auto comma = token.find(',');
          if (comma == std::string::npos) continue;
          double lon = std::stod(token.substr(0, comma));
          double lat = std::stod(token.substr(comma + 1));
          out.emplace_back(lon, lat);
      }
      return out;
  }

  void
  vehicleVisualizer::setPort(int port)
  {
      // Set the default port when an invalid port is specified
      if(port>=1 && port<=65535)
      {
          m_port=port;
      }
      else
      {
          NS_LOG_ERROR("Error: called setPort for vehicleVisualizer with an invalid port number. Using the default port.");
          m_port=48110;
      }
  }

  void
  vehicleVisualizer::setHTTPPort(int port)
  {
      // Set the default port when an invalid port is specified
      if(port>=1 && port<=65535)
      {
          m_httpport=port;
      }
      else
      {
          NS_LOG_ERROR("Error: called setPort for vehicleVisualizer with an invalid port number. Using the default port.");
          m_httpport=8080;
      }
  }
}

