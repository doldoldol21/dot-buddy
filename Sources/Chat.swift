import Foundation
// Ask the agent from the pet
func askAgent(_ q: String) {
  var r = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
  r.httpMethod = "POST"
  URLSession.shared.dataTask(with: r).resume()
}
