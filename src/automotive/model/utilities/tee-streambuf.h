#ifndef TEE_STREAMBUF_H
#define TEE_STREAMBUF_H

#include <iostream>
#include <fstream>
#include <string>
#include <streambuf>
#include <ctime>
#include <sstream>

namespace ns3 {

class TeeStreamBuf : public std::streambuf
{
public:
  TeeStreamBuf (std::streambuf *original, const std::string &filename)
    : m_original (original)
  {
    m_file.open (filename, std::ios::out | std::ios::app);
  }

  ~TeeStreamBuf ()
  {
    sync ();
    m_file.close ();
  }

protected:
  virtual int overflow (int c) override
  {
    if (c != EOF)
      {
        if (m_original && m_original->sputc (c) == EOF)
          return EOF;
        if (m_file.is_open ())
          {
            m_file.put (static_cast<char> (c));
            if (c == '\n')
              m_file.flush ();
          }
      }
    return c;
  }

  virtual int sync () override
  {
    int ret = 0;
    if (m_original)
      ret = m_original->pubsync ();
    if (m_file.is_open ())
      m_file.flush ();
    return ret;
  }

  virtual std::streamsize xsputn (const char *s, std::streamsize n) override
  {
    if (m_original)
      m_original->sputn (s, n);
    if (m_file.is_open ())
      m_file.write (s, n);
    return n;
  }

private:
  std::streambuf *m_original;
  std::ofstream m_file;
};

inline std::string
defaultLogFileName (const std::string &prefix)
{
  std::time_t t = std::time (nullptr);
  std::tm *tm = std::localtime (&t);
  std::ostringstream oss;
  oss << prefix << ".log."
      << (tm->tm_year + 1900) << "-"
      << (tm->tm_mon + 1 < 10 ? "0" : "") << (tm->tm_mon + 1) << "-"
      << (tm->tm_mday < 10 ? "0" : "") << tm->tm_mday;
  return oss.str ();
}

} // namespace ns3

#endif // TEE_STREAMBUF_H
