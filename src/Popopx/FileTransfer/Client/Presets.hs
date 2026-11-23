{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module Popopx.FileTransfer.Client.Presets
  ( defaultXFTPServers,
  ) where

import Data.List.NonEmpty (NonEmpty)
import Popopx.Messaging.Protocol (XFTPServerWithAuth)

defaultXFTPServers :: NonEmpty XFTPServerWithAuth
defaultXFTPServers =
  [ "xftp://OtONXJLyqB9g3QFSuOSfvBBoH5AdgccTbNbKCdaSWtw=@xftp1.popopx.im,im6alhiruuj3m2zhwnl3bzuujzpcg7hqgfljp3wmcgh3rrg3uysd7eqd.onion:8443",
    "xftp://B4WH5g5SRl7ioZx3gK9ruwkgv3lJGSQJ6QKIoV1JZMk=@xftp6.popopx.im,65fhxyz3yphhts4xy2vf2symvj2e4peb6zypry7ryg7qz7wbcxqyvxqd.onion:8443",
    "xftp://4GSglxXYIJswF-ysVo5RCycQ7vHF-85zTodA2wZCIQ8=@xftp8.popopx.im,wa47g3vf4xxfa246le62t6cwqjvww2eugecysqoznpgqt5we5kf2owyd.onion:8443"
  ]
