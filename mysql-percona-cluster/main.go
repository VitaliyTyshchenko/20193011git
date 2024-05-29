package main

import (
    "bufio"
    "encoding/json"
    "fmt"
    "io/ioutil"
    "os"
    "strings"
)

func main() {
    reader := bufio.NewReader(os.Stdin)
    var variables []map[string]string
    var mysqlrootpassword, mysqlsyncusername, mysqlsyncuserpassword string
    var confirmation string

    // Ask for MySQL root password once
    fmt.Print("Enter MySQL root password: ")
    mysqlrootpassword, _ = reader.ReadString('\n')
    mysqlrootpassword = strings.TrimSpace(mysqlrootpassword)

    // Ask for MySQL sync user name once
    fmt.Print("Enter MySQL sync user name: ")
    mysqlsyncusername, _ = reader.ReadString('\n')
    mysqlsyncusername = strings.TrimSpace(mysqlsyncusername)

    // Ask for MySQL sync user password once
    fmt.Print("Enter MySQL sync user password: ")
    mysqlsyncuserpassword, _ = reader.ReadString('\n')
    mysqlsyncuserpassword = strings.TrimSpace(mysqlsyncuserpassword)

    for {
        // Ask for server IP address
        fmt.Print("Enter server IP address: ")
        ip, _ := reader.ReadString('\n')
        ip = strings.TrimSpace(ip)

        // Ask for server password
        fmt.Print("Enter server password: ")
        password, _ := reader.ReadString('\n')
        password = strings.TrimSpace(password)

        // Store the IP and password in a map
        node := map[string]string{
            "IP":       ip,
            "Password": password,
        }
        variables = append(variables, node)

        // Ask for confirmation
        fmt.Print("That is or not yet? (yes/no): ")
        confirmation, _ = reader.ReadString('\n')
        confirmation = strings.TrimSpace(confirmation)

        // Check if confirmation is 'yes'
        if strings.ToLower(confirmation) == "yes" {
            // Create a final map to include MySQL root and sync user passwords
            finalVariables := map[string]interface{}{
                "mysqlrootpassword":    mysqlrootpassword,
                "mysqlsyncusername":    mysqlsyncusername,
                "mysqlsyncuserpassword": mysqlsyncuserpassword,
                "nodes":                variables,
            }

            // Marshal the final map to JSON
            jsonData, err := json.Marshal(finalVariables)
            if err != nil {
                fmt.Println("Error marshaling to JSON:", err)
                return
            }

            // Print JSON data
            fmt.Println("All variables provided in JSON format:")
            fmt.Println(string(jsonData))

            // Save JSON data to a file
            err = saveToFile(jsonData)
            if err != nil {
                fmt.Println("Error saving JSON data to file:", err)
                return
            }
            fmt.Println("JSON data saved to parameters.json")

            // Copy template file and replace placeholders for each server IP
            for _, v := range variables {
                ip := v["IP"]
                password := v["Password"]
                err := copyTemplate(ip, password)
                if err != nil {
                    fmt.Println("Error copying template file:", err)
                    return
                }
                fmt.Printf("Template file copied for server %s\n", ip)
            }

            break
        } else {
            fmt.Println("Please, provide server IP and password for next node.")
        }
    }
}

// Function to save JSON data to a file
func saveToFile(data []byte) error {
    file, err := os.Create("parameters.json")
    if err != nil {
        return err
    }
    defer file.Close()

    _, err = file.Write(data)
    if err != nil {
        return err
    }

    return nil
}

// Function to copy template file and replace placeholders
func copyTemplate(ip, password string) error {
    // Read template file
    templateData, err := ioutil.ReadFile("templateforpakageintallation")
    if err != nil {
        return err
    }

    // Replace placeholders with actual values
    template := string(templateData)
    template = strings.ReplaceAll(template, "$IP", ip)
    template = strings.ReplaceAll(template, "$password", password)

    // Create new file with server IP in the name
    fileName := fmt.Sprintf("server_%s_templateforpakageintallation", ip)
    err = ioutil.WriteFile(fileName, []byte(template), 0644)
    if err != nil {
        return err
    }

    return nil
}
